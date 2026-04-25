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
build_aeterna() {
    # ----- Backend -----
    # v1.5.0 ships a prebuilt linux/amd64 binary inside the source tarball
    # at backend/server (23 MB ELF, built with the same Go 1.24.12 from
    # github.com/alpyxn/aeterna/backend/cmd/server, requires GLIBC >= 2.34
    # which is satisfied by Debian bookworm = YunoHost 12). Using it
    # directly skips Go provisioning AND the multi-minute `go build` step
    # — saves roughly 3-5 minutes on amd64. The manifest's pinned source
    # sha256 already covers the binary's exact bytes, so trust doesn't
    # change.
    #
    # arm64 hosts have no prebuilt and fall back to compiling from source.
    local arch
    arch="$(dpkg --print-architecture)"

    if [ "$arch" = "amd64" ] && [ -x "$install_dir/backend/server" ]; then
        ynh_print_info "Using upstream's prebuilt linux/amd64 binary at backend/server (skips go build)"
        mv "$install_dir/backend/server" "$install_dir/backend/aeterna"
        chmod +x "$install_dir/backend/aeterna"
    else
        ynh_print_info "Compiling backend from source for $arch"

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
    fi

    # Both binaries are huge (23 MB each) and not part of the runtime: the
    # systemd unit only invokes backend/aeterna. Drop them so $install_dir
    # doesn't carry tens of MB of dead weight.
    ynh_safe_rm "$install_dir/backend/server"
    ynh_safe_rm "$install_dir/backend/main"

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
