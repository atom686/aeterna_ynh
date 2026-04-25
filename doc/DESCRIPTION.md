Aeterna is a lightweight, self-hosted **dead man's switch**. You write messages, optionally attach files, choose recipients, and check in regularly. If you stop checking in for a configurable interval, your messages and attachments are delivered to the recipients you chose — and any webhooks you configured fire.

Key properties:

- **Privacy-first** — messages and file attachments are encrypted at rest with AES-256-GCM. The encryption key lives only on your YunoHost server.
- **Multi-recipient delivery** — each switch can fan out to multiple email addresses (added in v1.5.0).
- **File attachments** — securely attach sensitive documents, photos or instructions to a switch; files are encrypted at rest and **deleted from disk immediately after a successful delivery**.
- **Lightweight** — single Go binary backend, SQLite single-file database, static React frontend. No external services required at runtime beyond an SMTP relay you provide.
- **Self-contained** — no third-party dependency calls home; you control everything.
- **Webhook-friendly** — trigger arbitrary URLs in addition to (or instead of) email when a switch fires.
- **Simple check-ins** — confirm you're alive via the web UI or a one-click link in any of the periodic check-in emails.

SMTP credentials are configured **in-app** after install (Settings → Email), so you can swap providers later without re-running the YunoHost installer.
