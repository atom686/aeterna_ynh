#!/bin/bash
# =============================================================================
# COMMON VARIABLES AND HELPERS
# =============================================================================
# Sourced by every script in scripts/. Holds:
#   - the toolchain versions consumed by the v2.1 helpers
#     ($go_version + ynh_go_install, $nodejs_version + ynh_nodejs_install)
#   - build_aeterna (Go backend + Vite frontend)
#   - generate_encryption_key
#   - assert_port_3000
#
# Note: helpers v2.1 has no ynh_exec_warn_less / ynh_exec_quiet wrappers —
# those were v2.0 names. v2.1 packagers just call commands directly; the
# trap installed by ynh_abort_if_errors handles failures.

# v1.5.0's backend/go.mod requires Go >= 1.24.12. Bumping this in lockstep
# with upstream's go.mod is enough — ynh_go_install reads $go_version,
# resolves it via goenv-latest, and adds the matching binary to $PATH.
go_version="1.24.12"

# Vite 7 needs Node >= 20.19; Tailwind 4 wants Node >= 20. The 'n' tool
# behind ynh_nodejs_install resolves "20" to the latest 20.x release.
nodejs_version="20"

# -----------------------------------------------------------------------------
# build_aeterna
# -----------------------------------------------------------------------------
# Compiles backend/cmd/server -> $install_dir/backend/aeterna and runs
# `vite build` -> $install_dir/frontend/dist/. Source layout is whatever
# ynh_setup_source produced from the upstream v1.5.0 tarball
# (top-level directories: backend/, frontend/).
build_aeterna() {
    # ----- Backend -----
    # ynh_go_install provisions Go via goenv at /opt/goenv and prepends
    # $GOENV_ROOT/versions/$go_version/bin to $PATH so `go` is callable
    # from anywhere downstream.
    ynh_go_install

    pushd "$install_dir/backend" >/dev/null
        # CGO_ENABLED=1 is required: github.com/mattn/go-sqlite3 ships C.
        # backend/cmd/ has TWO packages (server, keytool) — `go build -o`
        # cannot accept multiple packages, so target ./cmd/server explicitly.
        # GOFLAGS=-buildvcs=false suppresses the "error obtaining VCS status"
        # warning since the extracted tarball has no .git/.
        env CGO_ENABLED=1 GOFLAGS=-buildvcs=false \
            go build -trimpath -ldflags="-s -w" \
            -o "$install_dir/backend/aeterna" ./cmd/server
    popd >/dev/null

    # ----- Frontend -----
    # ynh_nodejs_install provisions Node via 'n' at /opt/node_n and
    # prepends $N_PREFIX/n/versions/node/$nodejs_version/bin to $PATH.
    ynh_nodejs_install

    pushd "$install_dir/frontend" >/dev/null
        # VITE_API_URL is baked at build time into the JS bundle. Set it to
        # the YunoHost subpath + /api so the api.js client hits the
        # nginx /api proxy block (see conf/nginx.conf). --base aligns
        # asset URLs with the same subpath.
        env VITE_API_URL="${path%/}/api" npm ci
        env VITE_API_URL="${path%/}/api" npm run build -- --base="${path%/}/"
    popd >/dev/null

    # We don't keep node_modules at runtime — the production deployment
    # is just the static dist/ output served by nginx.
    ynh_safe_rm "$install_dir/frontend/node_modules"
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
