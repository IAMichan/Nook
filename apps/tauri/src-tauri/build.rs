fn main() {
    // Nook's own relay is baked in at build time (`companion::nook_relay`).
    println!("cargo:rerun-if-env-changed=NOOK_RELAY_URL");
    tauri_build::build()
}
