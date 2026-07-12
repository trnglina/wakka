use std::collections::HashMap;
use std::env;
use std::path::PathBuf;
use std::process::Command;

fn dump_runtime_variables() -> HashMap<String, String> {
    let swipl = env::var("SWIPL").unwrap_or_else(|_| "swipl".to_string());

    let output = Command::new(&swipl)
        .arg("--dump-runtime-variables")
        .output()
        .unwrap_or_else(|e| {
            panic!(
                "failed to run `{swipl} --dump-runtime-variables`: {e}; \
                 ensure SWI-Prolog is installed and `swipl` is in the PATH, or set \
                 the SWIPL environment variable to its full path"
            )
        });

    if !output.status.success() {
        panic!(
            "`{swipl} --dump-runtime-variables` exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let text = String::from_utf8_lossy(&output.stdout);
    let mut vars = HashMap::new();
    for line in text.lines() {
        let line = line.trim().trim_end_matches(';');
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim().trim_matches('"');
        vars.insert(key.trim().to_string(), value.to_string());
    }
    vars
}

fn main() {
    let vars = dump_runtime_variables();

    let plbase = vars
        .get("PLBASE")
        .unwrap_or_else(|| panic!("swipl --dump-runtime-variables did not report PLBASE"));
    let pllibswipl = vars
        .get("PLLIBSWIPL")
        .unwrap_or_else(|| panic!("swipl --dump-runtime-variables did not report PLLIBSWIPL"));

    let include_dir = PathBuf::from(plbase).join("include");
    let header = include_dir.join("SWI-Prolog.h");
    if !header.exists() {
        panic!("SWI-Prolog.h not found at {}", header.display());
    }
    println!("cargo:rerun-if-changed={}", header.display());
    println!("cargo:rerun-if-env-changed=SWIPL");

    let lib_dir = PathBuf::from(pllibswipl)
        .parent()
        .unwrap_or_else(|| panic!("PLLIBSWIPL ({pllibswipl}) has no parent directory"))
        .to_path_buf();
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=dylib=swipl");

    let builder = bindgen::Builder::default()
        .header(header.to_str().unwrap())
        .clang_arg(format!("-I{}", include_dir.display()));

    let bindings = builder
        .generate()
        .expect("failed to generate SWI-Prolog FLI bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("failed to write bindings.rs");
}
