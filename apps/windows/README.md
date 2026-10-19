# Nook for Windows

Not yet implemented. This directory is reserved for the Windows desktop app.

- **Planned architecture:** System tray / top-edge utility built with WinUI 3 or WPF, backed by the portable Swift core in `packages/core`.
- **Platform services:** Windows UI Automation for screen context, Windows Credential Manager for secrets, and `RegisterHotKey` for global shortcuts.
- **Build & CI:** Will include a dedicated `windows-latest` CI workflow filtered on `apps/windows/**`.
