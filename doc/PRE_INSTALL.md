## Before you install

**1. SMTP relay required.** Aeterna sends scheduled check-in reminders and the final delivery emails through an SMTP relay you configure inside the app after installation (Settings → Email). Without working SMTP credentials, the dead man's switch cannot actually deliver anything. Have an SMTP host, port, username, password and a verified "From" address ready.

**2. Back up your encryption key.** On first install, this package generates an AES-256 encryption key at:

```
/home/yunohost.app/aeterna/secrets/encryption_key
```

All messages and uploaded attachments are encrypted with this key. **If you lose it, your data is unrecoverable.** YunoHost backups include the key alongside the database — keep both, and store at least one copy off the server.

**3. Build time and resources.** The package builds Aeterna from source at install/upgrade time (Go 1.24 backend + Vite/React frontend). The first install can take 3-5 minutes on a small VPS. You need at least **1 GB of free RAM** during install; runtime usage is much lower (~256 MB).

**4. Port 3000 must be free.** Aeterna's backend hardcodes `:3000` in `cmd/server/main.go` and ignores any `PORT` environment variable. The installer reserves port 3000 and aborts cleanly if something else is already bound there. Either stop the conflicting service or skip Aeterna on this YunoHost host.

**5. Permissions and the dead man's switch flow.**

By default this package installs Aeterna with the main permission set to `visitors`, so the URL is reachable without a YunoHost login. This is required for Aeterna's core flow: recipients of your switch click a link inside a delivery email, and they almost certainly don't have a YunoHost account on your server.

This is **not insecure**. Aeterna runs its own master-password authentication on top of the YunoHost permission. Visitors land on the public reveal page or the login form; nothing about your switches, settings, or webhooks can be touched without the master password you set during first-launch setup.

If you only ever access Aeterna from YunoHost-account devices and you're willing to lose delivery-to-non-YunoHost-recipients, you can switch the main permission to `all_users` either at install time or post-install via `yunohost user permission update aeterna.main --remove visitors --add all_users`.

**6. Architectures.** Builds are tested on `amd64` and `arm64` (the backend uses CGO via `go-sqlite3`, so cross-architecture binaries are not feasible — your YunoHost host must be one of those). 32-bit ARM (`armhf`) is not supported.
