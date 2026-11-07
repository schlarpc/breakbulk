use std::path::PathBuf;
use std::process::Command;

/// Run a tool and fail loudly.
fn run(cmd: &mut Command) {
    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!("could not start {cmd:?}: {e}"));
    assert!(status.success(), "{cmd:?} failed: {status}");
}

fn main() {
    let out = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());
    std::fs::write(out.join("gen.rs"), "pub const GENERATED: u32 = 42;\n").unwrap();
    let native = out.join("native");
    std::fs::create_dir_all(&native).unwrap();

    // A tiny stand-in for the cc crate: $CC and $AR from the environment,
    // an absolute source path, the object and archive in OUT_DIR.
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".into());
    let ar = std::env::var("AR").unwrap_or_else(|_| "ar".into());
    let obj = native.join("smoke.o");
    run(Command::new(&cc)
        .args(["-c", "-O1", "-g3", "-fPIC", "-o"])
        .arg(&obj)
        .arg(manifest.join("csrc/smoke.c")));
    run(Command::new(&ar)
        .arg("crs")
        .arg(native.join("libsmokec.a"))
        .arg(&obj));
    std::fs::remove_file(&obj).unwrap();
    // What the C compiler wrapper was given, for the tests.
    std::fs::write(
        out.join("nix-cflags-compile.txt"),
        std::env::var("NIX_CFLAGS_COMPILE").unwrap_or_default(),
    )
    .unwrap();

    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-changed=csrc/smoke.c");
    println!("cargo::rustc-cfg=smoke_cfg");
    println!("cargo::rustc-check-cfg=cfg(smoke_cfg)");
    println!("cargo::rustc-env=SMOKE_ENV=hello-from-build");
    println!("cargo::rustc-link-search=native={}", native.display());
    println!("cargo::rustc-link-lib=static=smokec");
    println!("cargo::warning=smoke build script ran");
}
