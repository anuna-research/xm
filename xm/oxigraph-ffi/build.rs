// SPDX-FileCopyrightText: 2026 Hugo O'Connor, Anuna Research
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Build script to generate C headers using cbindgen

fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();

    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(cbindgen::Config::from_file("cbindgen.toml").unwrap())
        .generate()
        .expect("Unable to generate C bindings")
        .write_to_file("xm_ffi.h");
}
