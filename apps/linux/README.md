# Nook voor Linux

Nog niet geschreven. Deze map is gereserveerd voor de Linux-app.

- Voorstel: GTK 4 of Qt, met een statusicoon (AppIndicator) in plaats van de notch; de gedeelde kern uit `packages/core` bouwt met Swift op Linux (`scripts/core-tests.sh` doet dat al voor de bestaande kern).
- Geheimen: libsecret. Scherm lezen verschilt tussen X11 en Wayland (AT-SPI waar mogelijk).
- Zet hier straks het project en een CI-job (`ubuntu-latest`) met een `paths:`-filter op `apps/linux/**`.
