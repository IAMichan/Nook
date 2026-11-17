//! Generates the list of translation catalogs: every `src/i18n/catalog/*.rs` file (except `mod.rs`) becomes a module
//! and its `ROWS` join `catalog::ALL`. A new area only adds its own file, so parallel changes don't all edit one
//! shared list (the cause of most merge conflicts there).

use std::{env, fs, path::Path};

fn main() {
    let dir = Path::new(&env::var("CARGO_MANIFEST_DIR").unwrap()).join("src/i18n/catalog");
    println!("cargo:rerun-if-changed={}", dir.display());
    let mut names: Vec<String> = fs::read_dir(&dir)
        .expect("src/i18n/catalog")
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            let stem = path.file_stem()?.to_str()?.to_string();
            (path.extension()? == "rs" && stem != "mod").then_some(stem)
        })
        .collect();
    names.sort();
    let mut out = String::new();
    for name in &names {
        let file = dir.join(format!("{name}.rs"));
        out.push_str(&format!("#[path = {:?}]\nmod {name};\n", file.display().to_string()));
    }
    out.push_str("pub const ALL: &[&[Row]] = &[\n");
    for name in &names {
        out.push_str(&format!("    {name}::ROWS,\n"));
    }
    out.push_str("];\n");
    fs::write(Path::new(&env::var("OUT_DIR").unwrap()).join("i18n_catalogs.rs"), out).unwrap();
}
