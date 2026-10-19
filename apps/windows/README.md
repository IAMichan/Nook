# Nook voor Windows

Nog niet geschreven. Deze map is gereserveerd voor de Windows-app.

- Voorstel: een tray-app (geen notch) met WinUI 3 of WPF; de gedeelde kern uit `packages/core` bouwt met Swift op Windows.
- Platformdiensten die op macOS in `Services/` zitten (scherm lezen, agenda, hotkeys, geheimen) hebben hier een eigen implementatie nodig: UI Automation, Windows Credential Manager, `RegisterHotKey`.
- Zet hier straks het project en een CI-job (`windows-latest`) met een `paths:`-filter op `apps/windows/**`.
