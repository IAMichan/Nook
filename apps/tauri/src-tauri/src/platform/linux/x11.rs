//! X11: de vensters op het scherm (volgorde, titel, app, pid), een schermafbeelding, hoe lang je niets deed, en een
//! toetsdruk voor plakken (XTEST). Onder Wayland zonder XWayland is er geen X11; dan valt de rest terug op AT-SPI.

use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt, ImageFormat, MapState, Window};
use x11rb::rust_connection::RustConnection;

pub struct X11 {
    conn: RustConnection,
    root: Window,
    width: u16,
    height: u16,
}

/// Een venster zoals X11 het kent.
#[derive(Debug, Clone)]
pub struct XWindow {
    pub id: u32,
    pub title: String,
    /// WM_CLASS (de klasse, bv. "Firefox").
    pub class: String,
    pub pid: u32,
    pub x: i16,
    pub y: i16,
    pub width: u16,
    pub height: u16,
}

impl X11 {
    pub fn connect() -> Option<Self> {
        std::env::var_os("DISPLAY")?;
        let (conn, screen) = x11rb::connect(None).ok()?;
        let s = &conn.setup().roots[screen];
        let (root, width, height) = (s.root, s.width_in_pixels, s.height_in_pixels);
        Some(Self { conn, root, width, height })
    }

    fn atom(&self, name: &str) -> Option<u32> {
        Some(self.conn.intern_atom(false, name.as_bytes()).ok()?.reply().ok()?.atom)
    }

    fn property32(&self, window: Window, name: &str, kind: AtomEnum) -> Vec<u32> {
        let Some(atom) = self.atom(name) else { return vec![] };
        self.conn
            .get_property(false, window, atom, kind, 0, 4096)
            .ok()
            .and_then(|c| c.reply().ok())
            .and_then(|r| r.value32().map(|v| v.collect()))
            .unwrap_or_default()
    }

    fn text_property(&self, window: Window, name: &str) -> String {
        let Some(atom) = self.atom(name) else { return String::new() };
        self.conn
            .get_property(false, window, atom, AtomEnum::ANY, 0, 4096)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|r| String::from_utf8_lossy(&r.value).to_string())
            .unwrap_or_default()
    }

    fn title(&self, window: Window) -> String {
        let net = self.text_property(window, "_NET_WM_NAME");
        if net.is_empty() {
            self.text_property(window, "WM_NAME")
        } else {
            net
        }
    }

    fn class(&self, window: Window) -> String {
        let raw = self.text_property(window, "WM_CLASS");
        let parts: Vec<&str> = raw.split('\0').filter(|s| !s.is_empty()).collect();
        parts.last().or(parts.first()).map(|s| s.to_string()).unwrap_or_default()
    }

    fn describe(&self, id: Window) -> Option<XWindow> {
        let attributes = self.conn.get_window_attributes(id).ok()?.reply().ok()?;
        if attributes.map_state != MapState::VIEWABLE {
            return None;
        }
        let geometry = self.conn.get_geometry(id).ok()?.reply().ok()?;
        let origin = self.conn.translate_coordinates(id, self.root, 0, 0).ok()?.reply().ok()?;
        Some(XWindow {
            id,
            title: self.title(id),
            class: self.class(id),
            pid: self.property32(id, "_NET_WM_PID", AtomEnum::CARDINAL).first().copied().unwrap_or(0),
            x: origin.dst_x,
            y: origin.dst_y,
            width: geometry.width,
            height: geometry.height,
        })
    }

    /// De vensters van boven naar onder. Met een windowmanager uit `_NET_CLIENT_LIST_STACKING`; zonder (bv. Xvfb)
    /// de zichtbare kinderen van de root.
    pub fn windows(&self) -> Vec<XWindow> {
        self.all_windows().into_iter().filter(|w| w.width > 200 && w.height > 100).collect()
    }

    /// Every viewable window with a title or class, small ones included (a sharing bar of a call app or browser).
    pub fn all_windows(&self) -> Vec<XWindow> {
        let mut ids = self.property32(self.root, "_NET_CLIENT_LIST_STACKING", AtomEnum::WINDOW);
        if ids.is_empty() {
            ids = self.conn.query_tree(self.root).ok().and_then(|c| c.reply().ok()).map(|t| t.children).unwrap_or_default();
        }
        ids.reverse();
        ids.into_iter().filter_map(|id| self.describe(id)).filter(|w| !(w.title.is_empty() && w.class.is_empty())).collect()
    }

    /// The screen saver is on (or the display blanked by it): nobody is looking at the screen.
    pub fn screen_saver_on(&self) -> bool {
        use x11rb::protocol::screensaver::{ConnectionExt as _, State};
        self.conn.screensaver_query_info(self.root).ok().and_then(|c| c.reply().ok()).is_some_and(|info| info.state == u8::from(State::ON))
    }

    /// Het actieve venster: `_NET_ACTIVE_WINDOW`, anders het bovenste.
    pub fn active(&self) -> Option<u32> {
        self.property32(self.root, "_NET_ACTIVE_WINDOW", AtomEnum::WINDOW).first().copied().filter(|id| *id != 0)
    }

    /// Pixels van een stuk van het scherm als RGBA. Alleen 24/32-bits schermen (de gewone).
    pub fn capture(&self, x: i16, y: i16, width: u16, height: u16) -> Result<(Vec<u8>, u32, u32), String> {
        let x = x.max(0);
        let y = y.max(0);
        let width = width.min(self.width.saturating_sub(x as u16));
        let height = height.min(self.height.saturating_sub(y as u16));
        if width == 0 || height == 0 {
            return Err("Dit venster staat niet op het scherm.".into());
        }
        let reply = self
            .conn
            .get_image(ImageFormat::Z_PIXMAP, self.root, x, y, width, height, !0)
            .map_err(|e| e.to_string())?
            .reply()
            .map_err(|e| format!("Schermafbeelding mislukt: {e}"))?;
        let bpp = self.conn.setup().pixmap_formats.iter().find(|f| f.depth == reply.depth).map(|f| f.bits_per_pixel).unwrap_or(32);
        if bpp != 32 {
            return Err(format!("Dit scherm gebruikt {bpp} bits per pixel; Nook leest alleen 24/32-bits schermen."));
        }
        let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
        for px in reply.data.chunks_exact(4) {
            rgba.extend_from_slice(&[px[2], px[1], px[0], 255]);
        }
        Ok((rgba, width as u32, height as u32))
    }

    pub fn capture_window(&self, window: &XWindow) -> Result<(Vec<u8>, u32, u32), String> {
        self.capture(window.x, window.y, window.width, window.height)
    }

    pub fn screen_size(&self) -> (u16, u16) {
        (self.width, self.height)
    }

    /// Milliseconden sinds de laatste invoer (XScreenSaver-extensie).
    pub fn idle_ms(&self) -> Option<u32> {
        use x11rb::protocol::screensaver::ConnectionExt as _;
        Some(self.conn.screensaver_query_info(self.root).ok()?.reply().ok()?.ms_since_user_input)
    }

    fn keycode(&self, keysym: u32) -> Option<u8> {
        let setup = self.conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let mapping = self.conn.get_keyboard_mapping(min, max - min + 1).ok()?.reply().ok()?;
        let per = mapping.keysyms_per_keycode as usize;
        mapping.keysyms.chunks(per.max(1)).position(|syms| syms.contains(&keysym)).map(|i| min + i as u8)
    }

    /// Ctrl+V (of Ctrl+Shift+V in een terminal) naar het venster dat de focus heeft.
    pub fn paste_keys(&self, shift: bool) -> Result<(), String> {
        use x11rb::protocol::xtest::ConnectionExt as _;
        const XK_CONTROL_L: u32 = 0xffe3;
        const XK_SHIFT_L: u32 = 0xffe1;
        const XK_V: u32 = 0x0076;
        let control = self.keycode(XK_CONTROL_L).ok_or("Geen Ctrl-toets gevonden.")?;
        let v = self.keycode(XK_V).ok_or("Geen V-toets gevonden.")?;
        let shift_key = if shift { self.keycode(XK_SHIFT_L) } else { None };
        let press = |code: u8, down: bool| {
            let kind = if down { x11rb::protocol::xproto::KEY_PRESS_EVENT } else { x11rb::protocol::xproto::KEY_RELEASE_EVENT };
            self.conn.xtest_fake_input(kind, code, x11rb::CURRENT_TIME, self.root, 0, 0, 0).map(|_| ()).map_err(|e| e.to_string())
        };
        press(control, true)?;
        if let Some(s) = shift_key {
            press(s, true)?;
        }
        press(v, true)?;
        press(v, false)?;
        if let Some(s) = shift_key {
            press(s, false)?;
        }
        press(control, false)?;
        self.conn.flush().map_err(|e| e.to_string())
    }
}
