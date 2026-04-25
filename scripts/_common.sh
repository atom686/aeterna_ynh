#!/bin/bash
# =============================================================================
# COMMON VARIABLES AND HELPERS
# =============================================================================
# Sourced by every script in scripts/. Holds:
#   - pinned toolchain versions
#   - install_go / remove_go (no ynh helper for Go in v2.1)
#   - build_aeterna (Go backend + Vite frontend)
#   - generate_encryption_key
#   - assert_port_3000

# v1.5.0's backend/go.mod requires Go >= 1.24.12. Bump in lockstep with
# upstream's go.mod when bumping the source version.
GO_VERSION="1.24.12"

# Vite 7 needs Node >= 20.19; Tailwind 4 wants Node >= 20. Use the
# YunoHost-provided n+nvm setup which tracks LTS for the major version.
nodejs_version="20"

# -----------------------------------------------------------------------------
# install_go
# -----------------------------------------------------------------------------
# YunoHost helpers v2.1 has no ynh_install_go, so we fetch the official
# tarball into $install_dir/.go and put it on PATH for the duration of
# the install/upgrade. The directory is wiped by remove_go right after
# the build to keep the runtime install_dir slim.
install_go() {
    local arch
    case "$(dpkg --print-architecture)" in
        amd64) arch="amd64" ;;
        arm64) arch="arm64" ;;
        *) ynh_die --message="Aeterna's Go build is only available for amd64 and arm64; got $(dpkg --print-architecture)" ;;
    esac

    local tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
    local url="https://go.dev/dl/${tarball}"

    mkdir -p "$install_dir/.go"
    pushd "$install_dir/.go" >/dev/null
        ynh_exec_warn_less wget --quiet --show-progress -O "$tarball" "$url"
        tar -xf "$tarball" --strip-components=1
        rm -f "$tarball"
    popd >/dev/null

    export PATH="$install_dir/.go/bin:$PATH"
    export GOCACHE="$install_dir/.go/cache"
    export GOPATH="$install_dir/.go/path"
    # -buildvcs=false avoids requiring git history inside the extracted tarball
    export GOFLAGS="-buildvcs=false"
}

# -----------------------------------------------------------------------------
# remove_go
# -----------------------------------------------------------------------------
remove_go() {
    ynh_safe_rm "$install_dir/.go"
}

# -----------------------------------------------------------------------------
# build_aeterna
# -----------------------------------------------------------------------------
# Compiles backend/cmd/server -> $install_dir/backend/aeterna
# and runs `vite build` -> $install_dir/frontend/dist/.
# Source layout is whatever ynh_setup_source produced from the upstream
# v1.5.0 tarball (top-level directories: backend/, frontend/).
build_aeterna() {
    # ----- Backend -----
    install_go

    pushd "$install_dir/backend" >/dev/null
        # CGO_ENABLED=1 is required: github.com/mattn/go-sqlite3 ships C.
        # backend/cmd/ has TWO packages (server, keytool) — `go build -o`
        # cannot accept multiple packages, so target ./cmd/server explicitly.
        ynh_exec_warn_less env CGO_ENABLED=1 \
            "$install_dir/.go/bin/go" build -trimpath -ldflags="-s -w" \
            -o "$install_dir/backend/aeterna" ./cmd/server
    popd >/dev/null

    remove_go

    # ----- Frontend -----
    ynh_install_nodejs --nodejs_version="$nodejs_version"
    ynh_use_nodejs

    pushd "$install_dir/frontend" >/dev/null
        # VITE_API_URL is baked at build time into the JS bundle. Set it to
        # the YunoHost subpath + /api so the api.js client hits the
        # nginx /api proxy block (see conf/nginx.conf). --base aligns
        # asset URLs with the same subpath.
        ynh_exec_warn_less env \
            VITE_API_URL="${path%/}/api" \
            npm ci
        ynh_exec_warn_less env \
            VITE_API_URL="${path%/}/api" \
            npm run build -- --base="${path%/}/"
    popd >/dev/null

    # We don't keep node_modules — the production runtime is just the
    # static dist/ output served by nginx.
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
