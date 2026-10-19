# Nook for Linux

Not yet implemented. This directory is reserved for the Linux desktop app.

- **Planned architecture:** GTK 4 or Qt with a status bar indicator in place of the notch, backed by the portable Swift core in `packages/core` (which already compiles and passes tests on Linux via `scripts/core-tests.sh`).
- **Platform services:** `libsecret` for credential storage and AT-SPI for accessibility screen context.
- **Build & CI:** Will include a dedicated `ubuntu-latest` CI workflow filtered on `apps/linux/**`.
