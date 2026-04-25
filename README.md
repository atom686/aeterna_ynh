<!--
N.B.: This README was hand-written for the initial package. When the app
is submitted to the YunoHost catalog, the official tooling regenerates it
from manifest.toml + doc/. Until then, edit this file and doc/DESCRIPTION.md
in sync.
-->

# Aeterna for YunoHost

[![Integration level](https://dash.yunohost.org/integration/aeterna.svg)](https://ci-apps.yunohost.org/ci/apps/aeterna/)
[![Install Aeterna with YunoHost](https://install-app.yunohost.org/install-with-yunohost.svg)](https://install-app.yunohost.org/?app=aeterna)

> *This package allows you to install Aeterna quickly and simply on a YunoHost server. If you don't already have YunoHost, please consult [the guide](https://yunohost.org/install) to learn how to install it.*

## Overview

Aeterna is a lightweight, self-hosted dead man's switch — write messages, optionally attach files, check in regularly, and if you stop checking in, your messages and files are delivered to the recipients you chose.

**Shipped version:** 1.5.0~ynh1

## Documentation and resources

- Official app website: <https://github.com/alpyxn/aeterna>
- Upstream app code repository: <https://github.com/alpyxn/aeterna>
- YunoHost documentation for this app: see `doc/` in this repository

## Developer info

To try the development branch:

```bash
sudo yunohost app install https://github.com/<your-fork>/aeterna_ynh/tree/main --debug
# or for upgrade:
sudo yunohost app upgrade aeterna -u https://github.com/<your-fork>/aeterna_ynh/tree/main --debug
```

## What this package does

- Builds the Go backend from source (Go 1.24) and the Vite/React frontend (Node 20) at install/upgrade time.
- Stores the SQLite database, uploaded attachments and the AES-256 encryption key under `/home/yunohost.app/aeterna/`.
- Runs the Go backend as a sandboxed systemd service under a dedicated `aeterna` user, listening on `127.0.0.1:3000`.
- Reverse-proxies `/api` to the backend through nginx and serves the built frontend statically.
- Defaults the main YunoHost permission to `visitors` so recipients without a YunoHost account can open delivery links from email; Aeterna's own master password still gates all management actions.
- Includes scripts for install, remove, upgrade, backup, restore and change_url.

## License

GPL-3.0-or-later, matching the upstream project.
