use std::env;
use std::path::PathBuf;

fn main() {
    let library = pkg_config::Config::new()
        .cargo_metadata(false)
        .probe("swipl")
        .expect("pkg-config could not find `swipl`; ensure swipl.pc is on PKG_CONFIG_PATH");

    let header = library
        .include_paths
        .iter()
        .map(|dir| dir.join("SWI-Prolog.h"))
        .find(|path| path.exists())
        .expect("SWI-Prolog.h not found in swipl include paths");

    println!("cargo:rerun-if-changed={}", header.display());

    let mut builder = bindgen::Builder::default().header(header.to_str().unwrap());
    for dir in &library.include_paths {
        builder = builder.clang_arg(format!("-I{}", dir.display()));
    }

    let bindings = builder
        .generate()
        .expect("failed to generate SWI-Prolog FLI bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("failed to write bindings.rs");
}
