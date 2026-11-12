//! The build-script stub writes its run record to the `BREAKBULK_RECORD` of
//! the Cargo that runs it, not to the one of the Cargo that compiled it
//! (another Cargo invocation over the same target directory may run a
//! stub without compiling it again).
//!
//! The stub is installed through the shim's own compile mode, with `true`
//! as the "rustc" (the shim asks it for file names; the link output's path
//! is explicit, so the empty answer is enough).

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const SHIM: &str = env!("CARGO_BIN_EXE_breakbulk-shim");
const RUN_TAG: &str = "fedcba9876543210";

struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn files(dir: &Path, prefix: &str) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .map(|r| {
            r.filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with(prefix))
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

fn run_stub(stub: &Path, pkg: &Path, metadata: &Path, record: Option<&Path>) -> Output {
    let out_dir = stub
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join(format!("p-{RUN_TAG}/out"));
    std::fs::create_dir_all(&out_dir).unwrap();
    let mut cmd = Command::new(stub);
    cmd.env_clear()
        .env("OUT_DIR", &out_dir)
        .env("CARGO_MANIFEST_DIR", pkg)
        .env("BREAKBULK_METADATA", metadata);
    if let Some(r) = record {
        cmd.env("BREAKBULK_RECORD", r);
    }
    cmd.output().unwrap()
}

#[test]
fn run_record_goes_to_the_running_invocation() {
    let tmp = Dir(std::env::temp_dir().join(format!("breakbulk-shim-stub-{}", std::process::id())));
    let t = &tmp.0;
    let _ = std::fs::remove_dir_all(t);
    let (compiled_in, run_in) = (t.join("record-0"), t.join("record-1"));
    let pkg = t.join("p");
    let build = t.join("target/debug/build/p-0123456789abcdef");
    for d in [&compiled_in, &run_in, &pkg, &build] {
        std::fs::create_dir_all(d).unwrap();
    }
    std::fs::write(pkg.join("Cargo.toml"), "").unwrap();
    let metadata = t.join("metadata.json");
    let meta = serde_json::json!({ "packages": [{
        "manifest_path": pkg.join("Cargo.toml"),
        "targets": [{ "kind": ["lib"], "name": "p" }],
    }]});
    std::fs::write(&metadata, meta.to_string()).unwrap();

    let stub = build.join("build-script-build");
    let compiled = Command::new(SHIM)
        .args(["true", "--crate-name", "build_script_build", "build.rs"])
        .args(["--crate-type", "bin", "-C", "metadata=0123456789abcdef"])
        .arg(format!("--emit=dep-info,link={}", stub.display()))
        .arg("--out-dir")
        .arg(&build)
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("BREAKBULK_RECORD", &compiled_in)
        .env("CARGO_MANIFEST_DIR", &pkg)
        .output()
        .unwrap();
    assert!(compiled.status.success(), "{compiled:?}");
    assert_eq!(files(&compiled_in, "compile-").len(), 1);
    let marker: serde_json::Value =
        serde_json::from_slice(&std::fs::read(build.join("breakbulk-stub.json")).unwrap()).unwrap();
    assert!(marker.get("record").is_none(), "{marker}");

    let ran = run_stub(&stub, &pkg, &metadata, Some(&run_in));
    assert!(ran.status.success(), "{ran:?}");
    let stdout = String::from_utf8_lossy(&ran.stdout);
    assert!(
        stdout.contains(&format!("cargo::rustc-cfg=__bb_{RUN_TAG}_cfg")),
        "{stdout}"
    );
    assert_eq!(files(&run_in, "run-").len(), 1);
    assert_eq!(files(&compiled_in, "run-"), Vec::<String>::new());

    // Without the variable there is no right directory: an error.
    let ran = run_stub(&stub, &pkg, &metadata, None);
    assert!(!ran.status.success());
    let stderr = String::from_utf8_lossy(&ran.stderr);
    assert!(stderr.contains("BREAKBULK_RECORD is not set"), "{stderr}");
    assert_eq!(files(&run_in, "run-").len(), 1);
}
