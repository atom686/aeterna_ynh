#!/bin/bash
# =============================================================================
# COMMON VARIABLES AND HELPERS
# =============================================================================
# Sourced by every script in scripts/. Holds:
#   - build_aeterna (Go backend + Vite frontend)
#   - generate_encryption_key
#   - assert_port_3000
#
# Toolchain versions live in manifest.toml under [resources.go].version and
# [resources.nodejs].version — the YunoHost resource provisioner installs
# them via goenv / n BEFORE any of these scripts run, then stores
# $go_version and $nodejs_version as app settings. The v2.1 helpers'
# auto-loaders read those and prepend the right bin dirs to $PATH on every
# script invocation, so we can call `go` and `npm` directly here without
# any explicit ynh_go_install / ynh_nodejs_install calls.
#
# Note: helpers v2.1 has no ynh_exec_warn_less / ynh_exec_quiet wrappers —
# those were v2.0 names. v2.1 packagers call commands directly; the trap
# installed by ynh_abort_if_errors handles failures.

# -----------------------------------------------------------------------------
# build_aeterna
# -----------------------------------------------------------------------------
# Compiles backend/cmd/server -> $install_dir/backend/aeterna and runs
# `vite build` -> $install_dir/frontend/dist/. Source layout is whatever
# ynh_setup_source produced from the upstream v1.5.0 tarball
# (top-level directories: backend/, frontend/).
apply_local_patches() {
    # Apply each *.patch in conf/patches/ (alphabetical order) to the freshly
    # extracted source tree. Dry-run first so we abort cleanly if upstream
    # restructured a file the patch depends on, instead of silently building
    # a broken binary.
    local patches_dir="$YNH_APP_BASEDIR/conf/patches"
    [ -d "$patches_dir" ] || return 0

    local p
    for p in "$patches_dir"/*.patch; do
        [ -e "$p" ] || continue   # nothing to apply
        ynh_print_info "Applying local patch $(basename "$p")"
        if ! patch -p1 --dry-run -d "$install_dir" --silent < "$p"; then
            ynh_die --message="Patch $(basename "$p") no longer applies cleanly to upstream — most likely Aeterna's source layout changed in a recent release. Review conf/patches/ against the current upstream tag."
        fi
        patch -p1 -d "$install_dir" --silent < "$p"
    done
}

build_aeterna() {
    # ----- Apply our local source patches BEFORE compile -----
    # Currently: 01-allow-7z.patch (extra archive type in attachments).
    # Each patch is reviewed against every Aeterna version bump.
    apply_local_patches

    # ----- Backend -----
    # We always compile from source even on amd64 where the upstream tarball
    # ships a prebuilt backend/server binary, because that prebuilt is
    # STALE: it's missing the multi-recipient feature that v1.5.0's release
    # notes advertise (no `RecipientEmails` struct field, no
    # `recipient_emails` JSON tag, no `normalizeRecipients` symbol — it's
    # an older build than the source code in the same tarball). Trusting
    # it silently drops every recipient after the first one in switches
    # with multiple recipients.
    #
    # The trade-off is ~3-5 min slower install/upgrade than the prebuilt
    # path would have given us; correctness wins.
    #
    # Go needs GOPATH (modules cache) and GOCACHE (build cache) explicitly.
    # The YunoHost install context runs the script with $HOME unset, so
    # Go's normal `~/go` and `~/.cache/go-build` defaults aren't available
    # and `go build` fails with "module cache not found". We point both at
    # ephemeral subdirs of $install_dir and wipe them after the build.
    local gobuild_workdir="$install_dir/.go-build"
    mkdir -p "$gobuild_workdir/path" "$gobuild_workdir/cache"

    pushd "$install_dir/backend" >/dev/null
        # CGO_ENABLED=1 is required: github.com/mattn/go-sqlite3 ships C.
        # backend/cmd/ has TWO packages (server, keytool) — `go build -o`
        # cannot accept multiple packages, so target ./cmd/server explicitly.
        # GOFLAGS=-buildvcs=false suppresses the "error obtaining VCS
        # status" warning since the extracted tarball has no .git/.
        env CGO_ENABLED=1 GOFLAGS=-buildvcs=false \
            GOPATH="$gobuild_workdir/path" \
            GOMODCACHE="$gobuild_workdir/path/pkg/mod" \
            GOCACHE="$gobuild_workdir/cache" \
            go build -trimpath -ldflags="-s -w" \
            -o "$install_dir/backend/aeterna" ./cmd/server
    popd >/dev/null

    ynh_safe_rm "$gobuild_workdir"

    # Drop the upstream prebuilt binaries (23 MB each); the systemd unit
    # only invokes our freshly-compiled $install_dir/backend/aeterna.
    ynh_safe_rm "$install_dir/backend/server"
    ynh_safe_rm "$install_dir/backend/main"

    # Smoke-check that 01-allow-7z.patch actually landed in the binary.
    # If `apply_local_patches` ever silently no-ops (e.g. patch file lost,
    # find skipped a hidden file), we want to fail loudly instead of
    # shipping a binary that secretly rejects .7z files.
    if ! grep -q "application/x-7z-compressed" "$install_dir/backend/aeterna"; then
        ynh_die --message="Build smoke-check failed: compiled backend/aeterna does not contain the .7z MIME prefix. The local patch was either skipped or the build silently dropped the change."
    fi

    # ----- Frontend -----
    # Same $HOME-unset story as Go above: npm caches into $HOME/.npm by
    # default, which fails when HOME isn't set. Point npm_config_cache at
    # an ephemeral subdir so `npm ci` can cache happily.
    local npm_workdir="$install_dir/.npm-build"
    mkdir -p "$npm_workdir"

    pushd "$install_dir/frontend" >/dev/null
        # VITE_API_URL is baked at build time into the JS bundle. Set it to
        # the YunoHost subpath + /api so the api.js client hits the
        # nginx /api proxy block (see conf/nginx.conf). --base aligns
        # asset URLs with the same subpath.
        env VITE_API_URL="${path%/}/api" \
            npm_config_cache="$npm_workdir" \
            npm ci
        env VITE_API_URL="${path%/}/api" \
            npm_config_cache="$npm_workdir" \
            npm run build -- --base="${path%/}/"
    popd >/dev/null

    # Drop both node_modules and the npm cache; the production deployment
    # is just the static dist/ output served by nginx.
    ynh_safe_rm "$install_dir/frontend/node_modules"
    ynh_safe_rm "$npm_workdir"
}

# -----------------------------------------------------------------------------
# generate_encryption_key
# -----------------------------------------------------------------------------
# AES-256 key the backend reads via --encryption-key-file. Only created
# on first install — never on upgrade — so existing encrypted data
# remains decryptable.
generate_encryption_key() {
    mkdir -p "$data_dir/secrets"
    chmod 700 "$data_dir/secrets"
    if [ ! -s "$data_dir/secrets/encryption_key" ]; then
        openssl rand -base64 32 | tr -d '\n' > "$data_dir/secrets/encryption_key"
    fi
    chmod 600 "$data_dir/secrets/encryption_key"
    chown -R "$app:$app" "$data_dir/secrets"
}

# -----------------------------------------------------------------------------
# assert_port_3000
# -----------------------------------------------------------------------------
# v1.5.0's main.go ends with `app.Listen(":3000")` — the port is hardcoded
# and ignores any PORT/SERVER_PORT env var. If YunoHost's port allocator
# handed us anything else, nginx would proxy to a port nothing listens on,
# so we fail fast with a useful message instead.
assert_port_3000() {
    if [ "${port:-}" != "3000" ]; then
        ynh_die --message="Aeterna v1.5.0 hardcodes port 3000 in cmd/server/main.go but YunoHost allocated port ${port:-<unset>}. Free port 3000 (e.g. stop the service that has it, then 'yunohost firewall allow' / reinstall) and retry."
    fi
}
