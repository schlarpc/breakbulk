use std::collections::BTreeMap;
use std::os::unix::process::ExitStatusExt;
use std::process::ExitStatus;

use super::*;
use crate::spec::{PackageTarget, Platform};
use crate::test_util::TempDir;

const PKG: &str = "registry+https://github.com/rust-lang/crates.io-index#foo-sys@1.2.3";

fn unit(cwd: &Path) -> RenderedRun {
    RenderedRun {
        package: PKG.into(),
        platform: Platform::Target,
        links: Some("foo".into()),
        script: "/nix/store/c-build/build_script_build-1".into(),
        env: BTreeMap::from([("TARGET".into(), "x86_64-unknown-linux-gnu".into())]),
        out_dir: String::new(),
        cwd: cwd.display().to_string(),
        metadata_from: vec![],
        dylib_path_from: vec![],
        rust_version: None,
        targets: vec![PackageTarget {
            name: "foo_sys".into(),
            kind: vec!["lib".into()],
        }],
        nightly_features_allowed: false,
        env_capture: None,
        view: None,
        seed: None,
        remap: vec![],
        out_dir_remap: None,
    }
}

fn judge_with(r: &RenderedRun, status: i32, stdout: &str) -> Result<Success, Error> {
    judge_with_stderr(r, status, stdout, "")
}

fn judge_with_stderr(
    r: &RenderedRun,
    status: i32,
    stdout: &str,
    stderr: &str,
) -> Result<Success, Error> {
    judge_full(r, status, stdout, stderr).map_err(|f| f.error)
}

fn judge_full(
    r: &RenderedRun,
    status: i32,
    stdout: &str,
    stderr: &str,
) -> Result<Success, Failure> {
    let env = BTreeMap::from([("SET".to_owned(), "1".to_owned())]);
    judge(&Finished {
        run: r,
        argv: &["/s/build-script-build".into()],
        env: &env,
        out: Path::new("/o"),
        upstream_out_dirs: &[],
        status: ExitStatus::from_raw(status),
        stdout: stdout.as_bytes(),
        stderr_tail: stderr.as_bytes(),
    })
}

#[test]
fn success_parses_directives() {
    let t = TempDir::new("ok");
    std::fs::write(t.path().join("build.rs"), "").unwrap();
    let r = unit(t.path());
    let s = judge_with(
        &r,
        0,
        "noise\ncargo::rustc-cfg=a\ncargo::warning=careful\ncargo::rerun-if-changed=build.rs\ncargo::metadata=include=/o/inc\n",
    )
    .unwrap();
    assert_eq!(s.output.cfgs, ["a"]);
    assert_eq!(s.output.metadata, [("include".into(), "/o/inc".into())]);
    assert_eq!(s.warnings, ["warning: foo-sys@1.2.3: careful"]);
}

#[test]
fn non_zero_exit_fails_with_stdout_and_hints() {
    let t = TempDir::new("exit");
    let r = unit(t.path());
    let e = judge_with(
        &r,
        1 << 8,
        "cargo::rerun-if-changed=vendor/foo.c\ncargo::rerun-if-env-changed=FOO_DIR\ncargo::rerun-if-env-changed=SET\n",
    )
    .unwrap_err();
    assert!(
        e.0.starts_with("failed to run custom build command for `foo-sys v1.2.3`"),
        "{e}"
    );
    assert!(
        e.0.contains("process didn't exit successfully: `/s/build-script-build` (exit status: 1)"),
        "{e}"
    );
    assert!(
        e.0.contains("--- stdout\n  cargo::rerun-if-changed=vendor/foo.c"),
        "{e}"
    );
    assert!(
        e.0.contains("add it to `packages.foo-sys.extraSources`"),
        "{e}"
    );
    assert!(e.0.contains("reads `FOO_DIR`"), "{e}");
    assert!(e.0.contains("`packages.foo-sys.env.FOO_DIR`"), "{e}");
    assert!(!e.0.contains("reads `SET`"), "{e}");
}

#[test]
fn failure_ends_with_stderr_and_deduplicates_hints() {
    let t = TempDir::new("tail");
    let r = unit(t.path());
    let stderr: String = (0..30)
        .map(|i| format!("cmake line {i}\n"))
        .collect::<String>()
        + "thread 'main' panicked at build.rs:440:13:\nFailed to copy\n";
    let e = judge_with_stderr(
        &r,
        101 << 8,
        "cargo::rerun-if-env-changed=FOO_DIR\ncargo::rerun-if-env-changed=FOO_DIR\n\
         cargo::rerun-if-changed=vendor/foo.c\ncargo::rerun-if-changed=vendor/foo.c\n",
        &stderr,
    )
    .unwrap_err();
    assert_eq!(e.0.matches("reads `FOO_DIR`").count(), 1, "{e}");
    assert_eq!(
        e.0.matches("rerun-if-changed=vendor/foo.c`, but").count(),
        1,
        "{e}"
    );
    let tail =
        e.0.split("--- stderr (last 20 lines; all of it is above)\n")
            .nth(1)
            .expect("a stderr section");
    assert!(tail.trim_end().ends_with("Failed to copy"), "{e}");
    assert!(tail.contains("panicked at build.rs:440:13"), "{e}");
    assert!(!tail.contains("cmake line 11\n"), "{e}");
    assert!(tail.contains("cmake line 12\n"), "{e}");
    // Hints come before the stderr section.
    assert!(
        e.0.find("hint:").unwrap() < e.0.find("--- stderr").unwrap(),
        "{e}"
    );
}

/// The `rerun-if-env-changed` lines pkg-config-rs prints for one probe of
/// `libspa-0.2` on the native target (`Config::targeted_env_var`).
fn pkg_config_declarations() -> String {
    let t = "x86_64-unknown-linux-gnu";
    let mut out = String::from("cargo:rerun-if-env-changed=LIBSPA_0.2_NO_PKG_CONFIG\n");
    for base in [
        "PKG_CONFIG",
        "PKG_CONFIG_PATH",
        "PKG_CONFIG_LIBDIR",
        "PKG_CONFIG_SYSROOT_DIR",
    ] {
        for v in [
            format!("{base}_{t}"),
            format!("{base}_{}", t.replace('-', "_")),
            format!("HOST_{base}"),
            base.to_owned(),
        ] {
            out.push_str(&format!("cargo:rerun-if-env-changed={v}\n"));
        }
    }
    out.push_str("cargo:rerun-if-env-changed=LIBSPA_DIR\n");
    out
}

/// pkg-config-rs's `Error::Command` for a missing `pkg-config`, as a
/// build script's `unwrap` panics with it.
const PKG_CONFIG_MISSING: &str = "thread 'main' panicked at build.rs:8:10:\n\
    called `Result::unwrap()` on an `Err` value: \
    Could not run `PKG_CONFIG_ALLOW_SYSTEM_CFLAGS=1 pkg-config --libs --cflags libspa-0.2`\n\
    The pkg-config command could not be found.\n\
    \n\
    Most likely, you need to install a pkg-config package for your OS.\n";

/// The `--- stdout` and `--- stderr` sections, as written for `stdout` and
/// `stderr` (under 20 lines).
fn sections(stdout: &str, stderr: &str) -> (String, String) {
    let indent = |s: &str| s.lines().map(|l| format!("  {l}\n")).collect::<String>();
    (
        format!("  --- stdout\n{}", indent(stdout)),
        format!(
            "  --- stderr (last {} lines; all of it is above)\n{}",
            stderr.lines().count(),
            indent(stderr)
        ),
    )
}

#[test]
fn pkg_config_missing_gets_one_hint_and_a_summary() {
    let t = TempDir::new("pkgconfig");
    let r = unit(t.path());
    let stdout = pkg_config_declarations();
    let e = judge_with_stderr(&r, 101 << 8, &stdout, PKG_CONFIG_MISSING).unwrap_err();
    assert!(
        e.0.contains(
            "hint: `pkg-config` is not in the sandbox; add it with \
             `packages.foo-sys.nativeInputs = p: [ p.pkg-config ];`\n      \
             (the build script printed: The pkg-config command could not be found.)"
        ),
        "{e}"
    );
    assert!(
        e.0.contains(
            "hint: (17 unset variables of the `pkg-config` crate omitted, \
             matching `PKG_CONFIG*`, `*_NO_PKG_CONFIG`; they are normally left unset)"
        ),
        "{e}"
    );
    // The variable no recognizer covers keeps its own hint.
    assert!(e.0.contains("reads `LIBSPA_DIR`"), "{e}");
    assert!(!e.0.contains("`PKG_CONFIG_PATH`"), "{e}");
    assert_eq!(e.0.matches("hint:").count(), 3, "{e}");
    // Hints only add lines: stdout and the stderr tail are as printed.
    let (out, err) = sections(&stdout, PKG_CONFIG_MISSING);
    assert!(e.0.contains(&out), "{e}");
    assert!(e.0.ends_with(&err), "{e}");
}

#[test]
fn recognizers_need_their_fingerprint() {
    let t = TempDir::new("fingerprint");
    let r = unit(t.path());
    // The pkg-config message, but no pkg-config variable declared.
    let stdout = "cargo:rerun-if-env-changed=FOO_DIR\ncargo:rerun-if-env-changed=FOO_STATIC\n";
    let e = judge_with_stderr(&r, 101 << 8, stdout, PKG_CONFIG_MISSING).unwrap_err();
    assert!(!e.0.contains("nativeInputs"), "{e}");
    assert!(
        e.0.contains(
            "hint: the build script reads these unset variables (`rerun-if-env-changed`): \
             `FOO_DIR`, `FOO_STATIC`; set any it needs with `packages.foo-sys.env.<NAME>`"
        ),
        "{e}"
    );
    let (out, err) = sections(stdout, PKG_CONFIG_MISSING);
    assert!(e.0.contains(&out), "{e}");
    assert!(e.0.ends_with(&err), "{e}");
}

#[test]
fn recognized_failures() {
    let t = TempDir::new("recognized");
    let r = unit(t.path());
    let hint = |stdout: &str, stderr: &str| -> String {
        let e = judge_with_stderr(&r, 101 << 8, stdout, stderr).unwrap_err();
        e.0.lines()
            .filter(|l| l.starts_with("hint: "))
            .collect::<Vec<_>>()
            .join("\n")
    };
    // pkg-config ran, and found no library.
    let h = hint(
        &pkg_config_declarations(),
        "The system library `libspa-0.2` required by crate `libspa-sys` was not found.\n",
    );
    assert!(
        h.contains("no `libspa-0.2.pc`; add the package that provides `libspa-0.2` to `packages.foo-sys.inputs`"),
        "{h}"
    );
    // cc-rs, current and 1.0 wording.
    let cc = "cargo:rerun-if-env-changed=CC_x86_64-unknown-linux-gnu\n\
              cargo:rerun-if-env-changed=CC\ncargo:rerun-if-env-changed=CFLAGS\n";
    for err in [
        "\n\nerror occurred in cc-rs: failed to find tool \"cc\": No such file or directory (os error 2)\n\n",
        "error occurred: Failed to find tool. Is `cc` installed?\n",
    ] {
        let h = hint(cc, err);
        assert!(
            h.contains("the `cc` crate could not run `cc`; add the package that provides it to `packages.foo-sys.nativeInputs`"),
            "{h}"
        );
        assert!(
            h.contains("(3 unset variables of the `cc` crate omitted"),
            "{h}"
        );
    }
    // bindgen at run time: clang-sys's warning is the fingerprint.
    let h = hint(
        "cargo:warning=could not execute `llvm-config` one or more times, if the LLVM_CONFIG_PATH \
         environment variable is set to a full path to valid `llvm-config` executable it will be \
         used to try to find an instance of `libclang` on your system: \"couldn't execute `llvm-config --prefix`\"\n",
        "thread 'main' panicked at bindgen/lib.rs:618:31:\nUnable to find libclang: \"couldn't find any valid shared libraries matching: ['libclang.so']\"\n",
    );
    assert!(h.contains("p.rustPlatform.bindgenHook"), "{h}");
    assert_eq!(h.matches("hint:").count(), 1, "{h}");
    // openssl-sys.
    let h = hint(
        "cargo:rerun-if-env-changed=X86_64_UNKNOWN_LINUX_GNU_OPENSSL_DIR\nX86_64_UNKNOWN_LINUX_GNU_OPENSSL_DIR unset\n\
         cargo:rerun-if-env-changed=OPENSSL_DIR\nOPENSSL_DIR unset\n",
        "\nCould not find directory of OpenSSL installation, and this `-sys` crate cannot\n",
    );
    assert!(
        h.contains("`packages.foo-sys.inputs = p: [ p.openssl ];`"),
        "{h}"
    );
    assert!(
        h.contains("(2 unset variables of the `openssl-sys` crate omitted"),
        "{h}"
    );
    // prost-build: its own docs link is the fingerprint.
    let protoc = "Error: Custom { kind: NotFound, error: \"Could not find `protoc`. If `protoc` is \
                  installed, try setting the `PROTOC` environment variable to the path of the \
                  `protoc` binary. To install it on Debian, run `apt-get install protobuf-compiler`. \
                  It is also available at https://github.com/protocolbuffers/protobuf/releases  For \
                  more information: https://docs.rs/prost-build/#sourcing-protoc\" }\n";
    assert!(hint("", protoc).contains("p.protobuf"));
    // Without it, only the general not-found rule would see the message,
    // which needs the `NotFound`.
    let unrecognized = protoc
        .replace("docs.rs/prost-build", "example.com")
        .replace("kind: NotFound, ", "");
    assert!(!hint("", &unrecognized).contains("p.protobuf"));
    // cmake-rs.
    let h = hint(
        "CMAKE_x86_64-unknown-linux-gnu = None\nHOST_CMAKE = None\nCMAKE = None\n",
        "thread 'main' panicked at cmake/src/lib.rs:1132:5:\n\nfailed to execute command: \
         No such file or directory (os error 2)\nis `cmake` not installed?\n\nbuild script failed, must exit now\n",
    );
    assert!(
        h.contains("`packages.foo-sys.nativeInputs = p: [ p.cmake ];`"),
        "{h}"
    );
}

/// The hint lines of a run that failed with `stdout` and `stderr`.
fn hint_lines(stdout: &str, stderr: &str) -> Vec<String> {
    let t = TempDir::new("hints");
    let e = judge_with_stderr(&unit(t.path()), 101 << 8, stdout, stderr).unwrap_err();
    e.0.lines()
        .filter(|l| l.starts_with("hint: "))
        .map(str::to_owned)
        .collect()
}

#[test]
fn bindgen_without_its_declarations() {
    // libsqlite3-sys and libnghttp2 under deno: bindgen panics before it
    // prints any `rerun-if-env-changed`.
    let h = hint_lines(
        "",
        "thread 'main' panicked at bindgen/lib.rs:604:27:\nUnable to find libclang: \"couldn't find \
         any valid shared libraries matching: ['libclang.so', 'libclang-*.so'], set the \
         `LIBCLANG_PATH` environment variable to a path where one of these files can be found \
         (invalid: [])\"\n",
    );
    assert_eq!(
        h,
        ["hint: libclang is not in the sandbox; add \
          `packages.foo-sys.nativeInputs = p: [ p.rustPlatform.bindgenHook ];`"]
    );
}

#[test]
fn omitted_variables_name_only_the_patterns_that_matched() {
    let h = hint_lines(
        "cargo:rerun-if-env-changed=BINDGEN_EXTRA_CLANG_ARGS\n\
         cargo:rerun-if-env-changed=BINDGEN_EXTRA_CLANG_ARGS_x86_64-unknown-linux-gnu\n\
         cargo:rerun-if-env-changed=BINDGEN_EXTRA_CLANG_ARGS_x86_64_unknown_linux_gnu\n",
        "Unable to find libclang: \"couldn't find any valid shared libraries\"\n",
    );
    assert_eq!(
        h[1],
        "hint: (3 unset variables of the `bindgen/clang-sys` crate omitted, matching \
         `BINDGEN_EXTRA_CLANG_ARGS*`; they are normally left unset)"
    );
    let h = hint_lines(
        "cargo:rerun-if-env-changed=LIBCLANG_PATH\n",
        "Unable to find libclang\n",
    );
    assert!(
        h[1].starts_with("hint: (1 unset variable of the `bindgen/clang-sys` crate omitted, matching `LIBCLANG_PATH`; it is"),
        "{h:?}"
    );
}

#[test]
fn a_tool_not_found() {
    // wasmtime: a build script spawning cmake itself.
    let h = hint_lines(
        "",
        "thread 'main' panicked at build.rs:10:5:\nfailed to spawn `cmake`: Os { code: 2, kind: NotFound, message: \"No such file or directory\" }\n",
    );
    assert_eq!(
        h,
        ["hint: `cmake` is not in the sandbox; add it with \
          `packages.foo-sys.nativeInputs = p: [ p.cmake ];`"]
    );
    for (line, attr) in [
        ("sh: 1: nasm: not found", "nasm"),
        ("/bin/sh: line 1: make: command not found", "gnumake"),
        (
            "FileNotFoundError: [Errno 2] No such file or directory: 'git'",
            "git",
        ),
        (
            "/usr/bin/env: 'python3': No such file or directory",
            "python3",
        ),
        (
            "error: could not run \"/usr/bin/protoc\": No such file or directory",
            "protobuf",
        ),
    ] {
        let h = hint_lines("", &format!("{line}\n"));
        assert!(
            h.first()
                .is_some_and(|h| h.ends_with(&format!("p.{attr} ];`"))),
            "{line}: {h:?}"
        );
    }
    // A tool's name as a word, or without a not-found marker, is not enough.
    for line in [
        "No such file or directory; make sure the SDK is installed",
        "failed to run `cmake`: exit status 1",
        "No such file or directory: 'cmake-build/config.h'",
    ] {
        assert!(hint_lines("", &format!("{line}\n")).is_empty(), "{line}");
    }
}

#[test]
fn downloads_have_no_network() {
    // v8 under deno: a Python downloader, then curl, which is missing.
    let h = hint_lines(
        "Downloading https://github.com/denoland/rusty_v8/releases/download/v137.2.0/librusty_v8_release_x86_64-unknown-linux-gnu.a.gz\n",
        "Python downloader failed, trying with curl.\nthread 'main' panicked at build.rs:617:8:\n\
         called `Result::unwrap()` on an `Err` value: Os { code: 2, kind: NotFound, message: \"No such file or directory\" }\n",
    );
    assert_eq!(h.len(), 1, "{h:?}");
    assert!(h[0].contains("the sandbox has no network"), "{h:?}");
    assert!(h[0].contains("`packages.foo-sys.env.<NAME>`"), "{h:?}");
    for line in [
        "curl: (6) Could not resolve host: example.com",
        "error sending request: dns error: failed to lookup address information: Temporary failure in name resolution",
        "<urlopen error [Errno -3] Temporary failure in name resolution>",
    ] {
        let h = hint_lines("", &format!("{line}\n"));
        assert!(h.iter().any(|h| h.contains("no network")), "{line}: {h:?}");
    }
    // A library named curl is not a download.
    assert!(hint_lines("cargo:rustc-link-lib=curl\n", "error: linking failed\n").is_empty());
}

#[test]
fn script_output_naming_a_path_outside_the_view() {
    let t = TempDir::new("view");
    let root = t.path().join("source");
    std::fs::create_dir_all(root.join("crates/foo-sys")).unwrap();
    let mut r = unit(&root.join("crates/foo-sys"));
    r.view = Some(crate::spec::SourceView {
        root: root.display().to_string(),
        package_dir: "crates/foo-sys".into(),
        widen: crate::spec::Widen::ExtraSources,
        test_only: Vec::new(),
        custom: false,
    });
    let e = judge_with_stderr(
        &r,
        101 << 8,
        "cargo:rerun-if-changed=../../vendor/foo.c\n",
        &format!(
            "Missing symbols list {}/crates/foo-sys/../../ext/napi/symbols.json: Os {{ code: 2 }}\n",
            root.display()
        ),
    )
    .unwrap_err();
    assert!(
        e.0.contains(
            "hint: `ext/napi/symbols.json` is not in this unit's source view; if it is in the \
             repository, add it to `packages.foo-sys.extraSources`"
        ),
        "{e}"
    );
    // The declared path has its own hint only.
    assert!(
        e.0.contains("rerun-if-changed=../../vendor/foo.c`, but"),
        "{e}"
    );
    assert!(!e.0.contains("`vendor/foo.c` is not in"), "{e}");
}

#[test]
fn death_by_signal_names_the_signal() {
    let t = TempDir::new("sig");
    let e = judge_with(&unit(t.path()), 11, "").unwrap_err();
    assert!(e.0.contains("(signal: 11, SIGSEGV)"), "{e}");
    let e = judge_with(&unit(t.path()), 9, "").unwrap_err();
    assert!(e.0.contains("(signal: 9, SIGKILL)"), "{e}");
}

#[test]
fn error_directives_follow_cargo() {
    let t = TempDir::new("err");
    let r = unit(t.path());
    let e = judge_with(&r, 0, "cargo::error=no compiler\n").unwrap_err();
    assert!(e.0.contains("build script logged errors"), "{e}");
    // Leading whitespace: printed, but Cargo does not fail the run
    // (decision log #8).
    let s = judge_with(&r, 0, "  cargo::error=soft\n").unwrap();
    assert_eq!(s.warnings, ["error: foo-sys@1.2.3: soft"]);
    // A directive Cargo rejects fails the run with Cargo's message alone.
    let e = judge_full(
        &r,
        0,
        "cargo::warning=w\ncargo::rustc-link-arg-bins=x\n",
        "",
    )
    .unwrap_err();
    assert!(
        e.error
            .0
            .starts_with("invalid instruction `cargo::rustc-link-arg-bins`"),
        "{}",
        e.error
    );
    assert!(
        e.error.0.contains("does not have a bin target"),
        "{}",
        e.error
    );
    assert!(e.messages.is_empty(), "{:?}", e.messages);
    let e = judge_with(&r, 0, "cargo::bogus=x\n").unwrap_err();
    assert!(
        e.0.starts_with("invalid output in build script of `foo-sys v1.2.3`"),
        "{e}"
    );
    assert!(e.0.contains("Unknown key: `bogus`"), "{e}");
}

#[test]
fn failures_print_streamed_messages_first() {
    let t = TempDir::new("msgs");
    let r = unit(t.path());
    let stdout = "cargo::warning=w\ncargo::error=e\n  cargo::error=indented\n";
    let streamed = ["warning: foo-sys@1.2.3: w", "error: foo-sys@1.2.3: e"];
    // Logged errors: what Cargo collected while the script ran, then its
    // error alone.
    let e = judge_full(&r, 0, stdout, "").unwrap_err();
    assert_eq!(e.messages, streamed);
    assert!(
        e.error.0.starts_with("build script logged errors"),
        "{}",
        e.error
    );
    // An unsuccessful exit: the same, then the error with its context.
    let e = judge_full(&r, 1 << 8, stdout, "").unwrap_err();
    assert_eq!(e.messages, streamed);
    assert!(
        e.error.0.starts_with("failed to run custom build command"),
        "{}",
        e.error
    );
}

#[test]
fn missing_sources_warn_and_are_listed() {
    let t = TempDir::new("missing");
    let r = unit(t.path());
    let s = judge_with(
        &r,
        0,
        "cargo::rerun-if-changed=../shared/x.h\ncargo::rerun-if-changed=/usr/include/z.h\n",
    )
    .unwrap();
    assert_eq!(s.warnings.len(), 2, "{:?}", s.warnings);
    assert!(
        s.warnings[0].contains("packages.foo-sys.extraSources"),
        "{:?}",
        s.warnings
    );
    assert!(
        s.warnings[1].contains("packages.foo-sys.inputs"),
        "{:?}",
        s.warnings
    );
    // The same paths, each once, with the same hints, for the check.
    let declared: Vec<&str> = s.missing.iter().map(|m| m.declared.as_str()).collect();
    assert_eq!(declared, ["../shared/x.h", "/usr/include/z.h"]);
    // `..` resolved: the path reads as its place in the repository.
    let parent = t.path().parent().unwrap();
    assert_eq!(
        s.missing[0].path,
        parent.join("shared/x.h").display().to_string()
    );
    assert!(s.warnings[0].ends_with(&s.missing[0].hint), "{:?}", s);
    // Present paths, and paths in OUT_DIR the script created, are fine.
    std::fs::write(t.path().join("present"), "").unwrap();
    let s = judge_with(&r, 0, "cargo::rerun-if-changed=present\n").unwrap();
    assert!(s.missing.is_empty());
}

#[test]
fn dep_env_and_out_dir() {
    let r = unit(Path::new("/src"));
    let mut r2 = r.clone();
    r2.env.insert("OUT_DIR".into(), "/stale".into());
    let md = [
        MetadataFile {
            package: "z-sys".into(),
            version: "0.1.0".into(),
            links: Some("z".into()),
            metadata: vec![("include".into(), "/z/inc".into())],
            out: "/z-out".into(),
        },
        MetadataFile {
            package: "openssl-sys".into(),
            version: "0.9.0".into(),
            links: Some("open-ssl".into()),
            metadata: vec![("version-number".into(), "30".into())],
            out: "/ssl-out".into(),
        },
        // No `links`: nothing for dependents.
        MetadataFile {
            package: "plain".into(),
            version: "1.0.0".into(),
            links: None,
            metadata: vec![("ignored".into(), "x".into())],
            out: "/plain-out".into(),
        },
    ];
    let env = run_env(&r2, Path::new("/nix/store/o-out"), &md);
    assert_eq!(env["OUT_DIR"], "/nix/store/o-out");
    assert_eq!(env["DEP_Z_INCLUDE"], "/z/inc");
    assert_eq!(env["DEP_OPEN_SSL_VERSION_NUMBER"], "30");
    assert!(!env.keys().any(|k| k.starts_with("DEP_PLAIN")), "{env:?}");
    assert_eq!(env["TARGET"], "x86_64-unknown-linux-gnu");
}

#[test]
fn script_in_a_directory() {
    let t = TempDir::new("script");
    let f = t.path().join("build_script_build-1");
    std::fs::write(&f, "").unwrap();
    assert_eq!(script_path(t.path()).unwrap(), f);
    assert_eq!(script_path(&f).unwrap(), f);
    std::fs::write(t.path().join("other"), "").unwrap();
    assert!(script_path(t.path()).is_err());
}

/// A shell script as the build script, run end to end.
#[test]
fn run_mode_end_to_end() {
    use std::os::unix::fs::PermissionsExt;
    let t = TempDir::new("e2e");
    let src = t.path().join("src");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(src.join("marker"), "").unwrap();
    let script = t.path().join("build-script-build");
    std::fs::write(
        &script,
        "#!/bin/sh\n\
         test -f marker || exit 9\n\
         echo hi > \"$OUT_DIR/gen\"\n\
         echo \"cargo::rustc-link-search=native=$OUT_DIR\"\n\
         echo \"cargo::rustc-link-search=native=/elsewhere\"\n\
         echo \"cargo::metadata=root=$OUT_DIR\"\n\
         echo \"cargo::rustc-env=JOBS=$NUM_JOBS:$DEP_UP_KEY:$HOME:${PATH:-}\"\n",
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    let up = t.path().join("up-flags");
    std::fs::create_dir_all(&up).unwrap();
    crate::write_json(
        &up.join(METADATA_FILE),
        &MetadataFile {
            package: "up".into(),
            version: "0.1.0".into(),
            links: Some("up".into()),
            metadata: vec![("key".into(), "v".into())],
            out: "/up-out".into(),
        },
    )
    .unwrap();
    let mut r = unit(&src);
    r.script = script.display().to_string();
    r.metadata_from = vec![up.display().to_string()];
    r.env.insert("NUM_JOBS".into(), "99".into());
    let out = t.path().join("out");
    let flags = t.path().join("flags");
    let outer = Outer {
        vars: BTreeMap::from([
            ("out".into(), out.display().to_string()),
            ("flags".into(), flags.display().to_string()),
            ("NIX_BUILD_CORES".into(), "3".into()),
            ("TMPDIR".into(), t.path().display().to_string()),
            ("PATH".into(), "/leak".into()),
        ]),
    };
    run(&r, &outer).unwrap();
    assert_eq!(std::fs::read_to_string(out.join("gen")).unwrap(), "hi\n");
    let d = crate::read_directives(&flags).unwrap();
    // The shell may substitute its own default PATH, but never the outer one.
    assert_eq!(d.env[0].0, "JOBS");
    assert!(
        d.env[0].1.starts_with("3:v:/homeless-shelter:"),
        "{:?}",
        d.env
    );
    assert!(!d.env[0].1.contains("/leak"), "{:?}", d.env);
    assert!(d.library_paths[0].in_out_dir);
    assert!(!d.library_paths[1].in_out_dir);
    let m = crate::read_metadata(&flags).unwrap();
    assert_eq!(
        (m.package.as_str(), m.version.as_str()),
        ("foo-sys", "1.2.3")
    );
    assert_eq!(m.links.as_deref(), Some("foo"));
    assert_eq!(m.metadata, [("root".into(), out.display().to_string())]);
    assert_eq!(m.out, out.display().to_string());

    // A package without `links` writes one too, naming its package.
    r.links = None;
    run(&r, &outer).unwrap();
    let m = crate::read_metadata(&flags).unwrap();
    assert_eq!((m.package.as_str(), m.links), ("foo-sys", None));
    assert_eq!(m.out, out.display().to_string());
    r.links = Some("foo".into());

    // The script's exit status is reported.
    std::fs::write(&script, "#!/bin/sh\nkill -ABRT $$\n").unwrap();
    let e = run(&r, &outer).unwrap_err();
    assert!(e.0.contains("signal: 6, SIGABRT"), "{e}");
}

#[test]
fn cmake_state_is_removed_from_build_trees_only() {
    let t = TempDir::new("cmake");
    let out = t.path();
    let mk = |rel: &str, body: &str| {
        let p = out.join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, body).unwrap();
    };
    // The cmake crate's tree, with the installed library beside it.
    mk("build/CMakeCache.txt", "cache");
    mk(
        "build/CMakeFiles/CMakeConfigureLog.yaml",
        "TryCompile-abcdef",
    );
    mk(
        "build/CMakeFiles/CMakeScratch/TryCompile-abcdef/CMakeCache.txt",
        "",
    );
    mk("build/CMakeFiles/cm.dir/cm.c.o", "obj");
    mk("build/libcm.a", "lib");
    mk("build/sub/CMakeFiles/sub.dir/s.c.o", "obj");
    mk("lib/libcm.a", "lib");
    // A `CMakeFiles` that is not next to a cache is left alone.
    mk("other/CMakeFiles/keep", "");
    let removed = remove_cmake_state(out).unwrap();
    assert_eq!(removed, [out.join("build/CMakeFiles")]);
    assert!(!out.join("build/CMakeFiles").exists());
    for kept in [
        "build/CMakeCache.txt",
        "build/libcm.a",
        "build/sub/CMakeFiles/sub.dir/s.c.o",
        "lib/libcm.a",
        "other/CMakeFiles/keep",
    ] {
        assert!(out.join(kept).exists(), "{kept} was removed");
    }
    assert_eq!(remove_cmake_state(out).unwrap(), Vec::<PathBuf>::new());
}

#[test]
fn out_dir_inside_a_copy_of_cargos_layout() {
    let t = TempDir::new("layout");
    let out = t.path().join("out");
    // Classic layout: Cargo creates `deps` and `examples` beside `build`.
    let d = prepare_out_dir(
        &out,
        "x86_64-unknown-linux-gnu/debug/build/sdl2-sys-1a2b/out",
    )
    .unwrap();
    assert_eq!(
        d,
        out.join("x86_64-unknown-linux-gnu/debug/build/sdl2-sys-1a2b/out")
    );
    assert!(out.join("x86_64-unknown-linux-gnu/debug/deps").is_dir());
    assert!(out.join("x86_64-unknown-linux-gnu/debug/examples").is_dir());
    // The new layout creates neither.
    let out2 = t.path().join("out2");
    prepare_out_dir(&out2, "debug/build/build/1a2b/out").unwrap();
    assert!(out2.join("debug/build/build/1a2b/out").is_dir());
    assert!(!out2.join("debug/deps").exists());
    assert!(!out2.join("debug/build/deps").exists());
    // No relative path: the `out` itself.
    assert_eq!(prepare_out_dir(&out2, "").unwrap(), out2);

    std::fs::write(d.join("inside.txt"), "").unwrap();
    std::fs::write(out.join("x86_64-unknown-linux-gnu/debug/libSDL2.so"), "").unwrap();
    std::os::unix::fs::symlink(
        "/x",
        out.join("x86_64-unknown-linux-gnu/debug/deps/libSDL2.so"),
    )
    .unwrap();
    assert_eq!(
        files_outside(&out, &d).unwrap(),
        [
            "x86_64-unknown-linux-gnu/debug/deps/libSDL2.so",
            "x86_64-unknown-linux-gnu/debug/libSDL2.so"
        ]
    );
    assert!(files_outside(&d, &d).unwrap().is_empty());
}

#[test]
fn trim_paths_remap_gets_the_build_directory_pairs() {
    let mut r = unit(Path::new("/src"));
    r.out_dir = "t/debug/build/foo-sys-1/out".into();
    r.out_dir_remap = Some("/cargo/build-dir".into());
    r.remap = vec![
        ("/nix/store/up".into(), "/cargo/build-dir".into()),
        ("/nix/store/src".into(), "/cargo/deps/foo-sys-1.2.3".into()),
    ];
    r.env.insert(
        "CARGO_TRIM_PATHS_REMAP".into(),
        "/nix/store/src=/cargo/deps/foo-sys-1.2.3:/sysroot/lib/rustlib/src/rust=/rustc/abc".into(),
    );
    let env = run_env(
        &r,
        Path::new("/nix/store/o/t/debug/build/foo-sys-1/out"),
        &[],
    );
    assert_eq!(env["OUT_DIR"], "/nix/store/o/t/debug/build/foo-sys-1/out");
    assert_eq!(
        env["CARGO_TRIM_PATHS_REMAP"],
        "/nix/store/src=/cargo/deps/foo-sys-1.2.3:/nix/store/up=/cargo/build-dir:\
         /nix/store/o=/cargo/build-dir:/sysroot/lib/rustlib/src/rust=/rustc/abc"
    );
    // Without trim-paths Cargo sets the variable empty, and it stays so.
    r.env.insert("CARGO_TRIM_PATHS_REMAP".into(), String::new());
    assert_eq!(
        run_env(&r, Path::new("/x"), &[])["CARGO_TRIM_PATHS_REMAP"],
        ""
    );
}

#[test]
fn target_dirs_are_profile_and_deps_with_files() {
    let out = Path::new("/nix/store/o");
    let rel = "t/debug/build/foo-1/out";
    let files = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(
        target_dirs(
            out,
            rel,
            &files(&["t/debug/deps/libx.so", "t/debug/libx.so"])
        ),
        ["/nix/store/o/t/debug", "/nix/store/o/t/debug/deps"]
    );
    assert_eq!(
        target_dirs(
            out,
            rel,
            &files(&["t/debug/deps/libx.so", "t/debug/examples/libx.so"])
        ),
        ["/nix/store/o/t/debug/deps"]
    );
    assert!(target_dirs(out, rel, &[]).is_empty());
    // New layout, a package named `build`: the profile is before the first `build`.
    assert_eq!(
        target_dirs(out, "debug/build/build/1/out", &files(&["debug/libx.so"])),
        ["/nix/store/o/debug"]
    );
}
