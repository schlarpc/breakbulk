use std::path::Path;

use super::*;

const OUT: &str = "/nix/store/aaaa-ring-0.17.14-build-run";

fn targets() -> Vec<PackageTarget> {
    let t = |name: &str, kind: &[&str]| PackageTarget {
        name: name.into(),
        kind: kind.iter().map(|k| k.to_string()).collect(),
    };
    vec![
        t("mylib", &["lib"]),
        t("app", &["bin"]),
        t("tool-x", &["bin"]),
        t("integration", &["test"]),
        t("bench1", &["bench"]),
        t("ex", &["example"]),
        t("build-script-build", &["custom-build"]),
    ]
}

fn ctx_with<'a>(targets: &'a [PackageTarget], msrv: Option<&'a str>) -> ParseContext<'a> {
    ParseContext {
        pkg_descr: "ring v0.17.14",
        out_dir: Path::new(OUT),
        nightly_features_allowed: false,
        targets,
        rust_version: msrv,
    }
}

fn parse_ok(input: &str) -> BuildOutput {
    let t = targets();
    parse(input.as_bytes(), &ctx_with(&t, None)).unwrap()
}

fn parse_err(input: &str) -> String {
    let t = targets();
    parse(input.as_bytes(), &ctx_with(&t, None)).unwrap_err().0
}

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

fn kv(v: &[(&str, &str)]) -> Vec<(String, String)> {
    v.iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
}

#[test]
fn every_key_new_syntax() {
    let out = parse_ok(
        "cargo::rustc-cfg=foo\n\
         cargo::rustc-cfg=feature=\"bar\"\n\
         cargo::rustc-check-cfg=cfg(foo)\n\
         cargo::rustc-env=A=b=c\n\
         cargo::rustc-link-lib=static=ring_core\n\
         cargo::rustc-link-search=native=/nix/store/aaaa-ring-0.17.14-build-run/lib\n\
         cargo::rustc-flags=-l z -L /usr/lib\n\
         cargo::rustc-link-arg=-Wl,-z,now\n\
         cargo::rustc-link-arg-bins=bins\n\
         cargo::rustc-link-arg-bin=app=onlyapp\n\
         cargo::rustc-link-arg-tests=tests\n\
         cargo::rustc-link-arg-benches=benches\n\
         cargo::rustc-link-arg-examples=examples\n\
         cargo::metadata=root=/x\n\
         cargo::warning=careful\n\
         cargo::error=broken\n\
         cargo::rerun-if-changed=build.rs\n\
         cargo::rerun-if-env-changed=CC\n",
    );
    assert_eq!(out.cfgs, s(&["foo", "feature=\"bar\""]));
    assert_eq!(out.check_cfgs, s(&["cfg(foo)"]));
    assert_eq!(out.env, kv(&[("A", "b=c")]));
    assert_eq!(out.library_links, s(&["static=ring_core", "z"]));
    assert_eq!(
        out.library_paths,
        vec![
            LibraryPath {
                value: format!("native={OUT}/lib"),
                in_out_dir: true
            },
            LibraryPath {
                value: "/usr/lib".into(),
                in_out_dir: false
            },
        ]
    );
    let la = |kind, bin: Option<&str>, value: &str| LinkArg {
        kind,
        bin: bin.map(Into::into),
        value: value.into(),
    };
    assert_eq!(
        out.linker_args,
        vec![
            la(SpliceKind::RustcLinkArg, None, "-Wl,-z,now"),
            la(SpliceKind::RustcLinkArgBins, None, "bins"),
            la(SpliceKind::RustcLinkArgBin, Some("app"), "onlyapp"),
            la(SpliceKind::RustcLinkArgTests, None, "tests"),
            la(SpliceKind::RustcLinkArgBenches, None, "benches"),
            la(SpliceKind::RustcLinkArgExamples, None, "examples"),
        ]
    );
    assert_eq!(out.metadata, kv(&[("root", "/x")]));
    assert_eq!(
        out.log_messages,
        vec![
            LogMessage {
                severity: Severity::Warning,
                message: "careful".into()
            },
            LogMessage {
                severity: Severity::Error,
                message: "broken".into()
            },
        ]
    );
    assert!(out.has_errors());
    assert_eq!(out.rerun_if_changed, s(&["build.rs"]));
    assert_eq!(out.rerun_if_env_changed, s(&["CC"]));
}

#[test]
fn every_reserved_key_old_syntax() {
    let out = parse_ok(
        "cargo:rustc-cfg=foo\n\
         cargo:rustc-check-cfg=cfg(foo)\n\
         cargo:rustc-env=A=1\n\
         cargo:rustc-link-lib=z\n\
         cargo:rustc-link-search=/opt\n\
         cargo:rustc-flags=-lssl\n\
         cargo:rustc-link-arg=a\n\
         cargo:rustc-link-arg-bins=b\n\
         cargo:rustc-link-arg-bin=app=c\n\
         cargo:rustc-link-arg-tests=d\n\
         cargo:rustc-link-arg-benches=e\n\
         cargo:rustc-link-arg-examples=f\n\
         cargo:warning=w\n\
         cargo:rerun-if-changed=x\n\
         cargo:rerun-if-env-changed=Y\n",
    );
    assert_eq!(out.cfgs, s(&["foo"]));
    assert_eq!(out.check_cfgs, s(&["cfg(foo)"]));
    assert_eq!(out.env, kv(&[("A", "1")]));
    assert_eq!(out.library_links, s(&["z", "ssl"]));
    assert_eq!(out.library_paths.len(), 1);
    assert_eq!(out.linker_args.len(), 6);
    assert_eq!(out.log_messages.len(), 1);
    assert_eq!(out.rerun_if_changed, s(&["x"]));
    assert_eq!(out.rerun_if_env_changed, s(&["Y"]));
    assert!(out.metadata.is_empty());
}

#[test]
fn old_syntax_unknown_keys_are_metadata() {
    let out = parse_ok(
        "cargo:root=/x\n\
         cargo:include=/a=/b\n\
         cargo:error=not an error in the old syntax\n\
         cargo:metadata=k=v\n\
         cargo:rustc-link-arg-foo=x\n\
         cargo:KEY-with-Dash=v\n",
    );
    assert_eq!(
        out.metadata,
        kv(&[
            ("root", "/x"),
            ("include", "/a=/b"),
            ("error", "not an error in the old syntax"),
            // `cargo:metadata=k=v` is key `metadata`, value `k=v`.
            ("metadata", "k=v"),
            ("rustc-link-arg-foo", "x"),
            ("KEY-with-Dash", "v"),
        ])
    );
    assert!(out.log_messages.is_empty());
}

#[test]
fn new_syntax_unknown_key_is_error() {
    let e = parse_err("cargo::root=/x\n");
    assert!(e.contains("Unknown key: `root`"), "{e}");
    // `rustc-cdylib-link-arg` is known in both syntaxes, but `error` and
    // `metadata` are new-syntax only.
    let e = parse_err("cargo::rustc-link-arg-foo=x\n");
    assert!(e.contains("Unknown key: `rustc-link-arg-foo`"), "{e}");
}

#[test]
fn missing_equals() {
    let e = parse_err("cargo::rustc-cfg\n");
    assert!(e.contains("Expected a line with `cargo::KEY=VALUE`"), "{e}");
    // Old syntax without `=` is metadata without `=`: also an error.
    let e = parse_err("cargo:foo\n");
    assert!(e.contains("Expected a line with `cargo:KEY=VALUE`"), "{e}");
    // A bare prefix is an error in both syntaxes.
    assert!(parse_err("cargo:\n").contains("cargo:KEY=VALUE"));
    assert!(parse_err("cargo::\n").contains("cargo::KEY=VALUE"));
    // `cargo::metadata=k` lacks the second `=`.
    let e = parse_err("cargo::metadata=k\n");
    assert!(e.contains("`cargo::metadata=KEY=VALUE`"), "{e}");
}

#[test]
fn whitespace_and_line_endings() {
    let out = parse_ok(
        "  cargo::rustc-cfg=a  \r\n\
         \tcargo:rustc-cfg=b\t\n\
         cargo::rustc-cfg= c\n\
         cargo::rustc-env=K= v \n\
         cargo::rustc-cfg=\n\
         not a directive\n\
         CARGO::rustc-cfg=ignored\n\
         x cargo::rustc-cfg=ignored\n\
         \n",
    );
    // Lines are trimmed at both ends; the value keeps leading whitespace
    // after `=`, and may be empty.
    assert_eq!(out.cfgs, s(&["a", "b", " c", ""]));
    assert_eq!(out.env, kv(&[("K", " v")]));
}

#[test]
fn key_is_not_trimmed() {
    // New syntax: ` rustc-cfg` is an unknown key.
    let e = parse_err("cargo:: rustc-cfg=x\n");
    assert!(e.contains("Unknown key: ` rustc-cfg`"), "{e}");
    let e = parse_err("cargo::rustc-cfg =x\n");
    assert!(e.contains("Unknown key: `rustc-cfg `"), "{e}");
    // Old syntax: not a reserved prefix, so metadata with key ` rustc-cfg`.
    let out = parse_ok("cargo: rustc-cfg=x\n");
    assert_eq!(out.metadata, kv(&[(" rustc-cfg", "x")]));
    assert!(out.cfgs.is_empty());
}

#[test]
fn invalid_utf8_lines_are_skipped() {
    let t = targets();
    let mut input = b"cargo::rustc-cfg=a\n".to_vec();
    input.extend_from_slice(b"cargo::rustc-cfg=\xff\n");
    input.extend_from_slice(b"cargo::rustc-cfg=b");
    let out = parse(&input, &ctx_with(&t, None)).unwrap();
    assert_eq!(out.cfgs, s(&["a", "b"]));
}

#[test]
fn duplicates_are_kept_in_order() {
    let out = parse_ok(
        "cargo::rustc-cfg=a\n\
         cargo::rustc-cfg=a\n\
         cargo::rustc-link-lib=z\n\
         cargo::rustc-link-lib=z\n\
         cargo::rustc-env=K=1\n\
         cargo::rustc-env=K=2\n\
         cargo::metadata=k=1\n\
         cargo::metadata=k=2\n",
    );
    assert_eq!(out.cfgs, s(&["a", "a"]));
    assert_eq!(out.library_links, s(&["z", "z"]));
    assert_eq!(out.env, kv(&[("K", "1"), ("K", "2")]));
    assert_eq!(out.metadata, kv(&[("k", "1"), ("k", "2")]));
}

#[test]
fn rustc_flags_splitting() {
    let w = "w";
    let ok = |v: &str| parse_rustc_flags(v, w).unwrap();
    assert_eq!(ok(""), (vec![], vec![]));
    assert_eq!(ok("   "), (vec![], vec![]));
    assert_eq!(ok("-lfoo -Lbar"), (s(&["bar"]), s(&["foo"])));
    assert_eq!(ok("-l foo\t-L  bar"), (s(&["bar"]), s(&["foo"])));
    assert_eq!(
        ok("-L native=/a -lstatic=b -l dylib=c"),
        (s(&["native=/a"]), s(&["static=b", "dylib=c"]))
    );
    // The next word is taken as the value even when it looks like a flag.
    assert_eq!(ok("-l -L"), (vec![], s(&["-L"])));
    // Unicode whitespace separates words too.
    assert_eq!(ok("-lfoo\u{3000}-lbar"), (vec![], s(&["foo", "bar"])));
    // Errors.
    let e = parse_rustc_flags("-l", w).unwrap_err().0;
    assert!(
        e.starts_with("flag in rustc-flags has no value in w"),
        "{e}"
    );
    let e = parse_rustc_flags("-lfoo -C opt-level=3", w).unwrap_err().0;
    assert_eq!(
        e,
        "only `-l` and `-L` flags are allowed in w: `-lfoo -C opt-level=3`"
    );
    assert!(parse_rustc_flags("foo", w).is_err());
    assert!(parse_rustc_flags("--cfg x", w).is_err());
}

#[test]
fn rustc_flags_interleaves_with_other_directives() {
    let out = parse_ok(
        "cargo::rustc-link-lib=a\n\
         cargo::rustc-flags=-lb -L /p\n\
         cargo::rustc-link-lib=c\n\
         cargo::rustc-link-search=/q\n",
    );
    assert_eq!(out.library_links, s(&["a", "b", "c"]));
    let paths: Vec<_> = out.library_paths.iter().map(|p| p.value.as_str()).collect();
    assert_eq!(paths, ["/p", "/q"]);
    assert!(parse_err("cargo::rustc-flags=-C x\n").contains("only `-l` and `-L`"));
}

#[test]
fn link_search_classification() {
    let out = parse_ok(&format!(
        "cargo::rustc-link-search={OUT}\n\
         cargo::rustc-link-search={OUT}/lib\n\
         cargo::rustc-link-search=native={OUT}/lib\n\
         cargo::rustc-link-search=dependency={OUT}\n\
         cargo::rustc-link-search=crate={OUT}\n\
         cargo::rustc-link-search=framework={OUT}\n\
         cargo::rustc-link-search=all={OUT}\n\
         cargo::rustc-link-search=static={OUT}\n\
         cargo::rustc-link-search={OUT}-other/lib\n\
         cargo::rustc-link-search=lib\n\
         cargo::rustc-link-search=\n\
         cargo::rustc-flags=-L{OUT}/x -L /usr/lib\n"
    ));
    let got: Vec<bool> = out.library_paths.iter().map(|p| p.in_out_dir).collect();
    assert_eq!(
        got,
        [
            true, true, true, true, true, true, true,  // known kinds stripped
            false, // `static=` is not a search kind: the whole value is a relative path
            false, // shares a string prefix, not a path prefix
            false, // relative
            false, // empty
            true, false
        ]
    );
}

#[test]
fn link_arg_target_validation() {
    let lib_only = vec![PackageTarget {
        name: "l".into(),
        kind: vec!["lib".into()],
    }];
    let p = |input: &str| parse(input.as_bytes(), &ctx_with(&lib_only, None));
    for (key, kind) in [
        ("rustc-link-arg-bins", "bin"),
        ("rustc-link-arg-tests", "test"),
        ("rustc-link-arg-benches", "benchmark"),
        ("rustc-link-arg-examples", "example"),
    ] {
        for syntax in ["cargo:", "cargo::"] {
            let e = p(&format!("{syntax}{key}=x\n")).unwrap_err().0;
            assert_eq!(
                e,
                format!(
                    "invalid instruction `{syntax}{key}` from build script of `ring v0.17.14`\n\
                     The package ring v0.17.14 does not have a {kind} target."
                )
            );
        }
    }
    // rustc-link-arg itself needs no particular target.
    assert_eq!(p("cargo::rustc-link-arg=x\n").unwrap().linker_args.len(), 1);
}

#[test]
fn link_arg_bin() {
    let out = parse_ok("cargo::rustc-link-arg-bin=tool-x=--a=b\n");
    assert_eq!(
        out.linker_args,
        vec![LinkArg {
            kind: SpliceKind::RustcLinkArgBin,
            bin: Some("tool-x".into()),
            value: "--a=b".into()
        }]
    );
    let e = parse_err("cargo::rustc-link-arg-bin=nope=x\n");
    assert!(
        e.contains("does not have a bin target with the name `nope`"),
        "{e}"
    );
    // A test target named like a bin does not count.
    let e = parse_err("cargo::rustc-link-arg-bin=integration=x\n");
    assert!(e.contains("with the name `integration`"), "{e}");
    let e = parse_err("cargo:rustc-link-arg-bin=app\n");
    assert!(
        e.contains("The instruction should have the form cargo:rustc-link-arg-bin=BIN=ARG"),
        "{e}"
    );
    // An empty argument is accepted.
    assert_eq!(
        parse_ok("cargo::rustc-link-arg-bin=app=\n").linker_args[0].value,
        ""
    );
}

#[test]
fn cdylib_link_arg_both_spellings_and_warning() {
    // No cdylib target: warning, value still kept.
    let out = parse_ok("cargo::rustc-link-arg-cdylib=a\ncargo:rustc-cdylib-link-arg=b\n");
    let vals: Vec<_> = out
        .linker_args
        .iter()
        .map(|a| (a.kind, a.value.as_str()))
        .collect();
    assert_eq!(
        vals,
        [
            (SpliceKind::RustcLinkArgCdylib, "a"),
            (SpliceKind::RustcLinkArgCdylib, "b")
        ]
    );
    assert_eq!(out.log_messages.len(), 2);
    assert!(out.log_messages[0].message.starts_with(
        "cargo::rustc-link-arg-cdylib was specified in the build script of ring v0.17.14, but that package does not contain a cdylib target"
    ));
    assert!(
        out.log_messages[1]
            .message
            .starts_with("cargo:rustc-cdylib-link-arg was specified")
    );
    assert!(!out.has_errors());

    let cdylib = vec![PackageTarget {
        name: "l".into(),
        kind: vec!["cdylib".into(), "rlib".into()],
    }];
    let out = parse(
        b"cargo::rustc-link-arg-cdylib=a\n",
        &ctx_with(&cdylib, None),
    )
    .unwrap();
    assert!(out.log_messages.is_empty());
    // An example built as a cdylib is not a cdylib target for Cargo.
    let example = vec![PackageTarget {
        name: "e".into(),
        kind: vec!["example".into()],
    }];
    let out = parse(
        b"cargo::rustc-link-arg-cdylib=a\n",
        &ctx_with(&example, None),
    )
    .unwrap();
    assert_eq!(out.log_messages.len(), 1);
}

#[test]
fn rustc_env() {
    assert_eq!(parse_ok("cargo::rustc-env=A=\n").env, kv(&[("A", "")]));
    assert_eq!(parse_ok("cargo::rustc-env==v\n").env, kv(&[("", "v")]));
    let e = parse_err("cargo::rustc-env=A\n");
    assert_eq!(
        e,
        "Variable rustc-env has no value in build script of `ring v0.17.14`: A"
    );
}

#[test]
fn rustc_bootstrap() {
    let e = parse_err("cargo::rustc-env=RUSTC_BOOTSTRAP=1\n");
    assert!(e.starts_with("cannot set `RUSTC_BOOTSTRAP=1` from build script of `ring v0.17.14`."));
    // Only the exact name is refused.
    assert_eq!(
        parse_ok("cargo::rustc-env=RUSTC_BOOTSTRAPX=1\n").env,
        kv(&[("RUSTC_BOOTSTRAPX", "1")])
    );
    // On nightly, a warning, and the variable is not set.
    let t = targets();
    let mut ctx = ctx_with(&t, None);
    ctx.nightly_features_allowed = true;
    let out = parse(b"cargo:rustc-env=RUSTC_BOOTSTRAP=1\n", &ctx).unwrap();
    assert!(out.env.is_empty());
    assert_eq!(out.log_messages[0].severity, Severity::Warning);
}

#[test]
fn msrv_gate() {
    let t = targets();
    let p = |input: &str, msrv| parse(input.as_bytes(), &ctx_with(&t, Some(msrv)));
    for ok in ["1.77", "1.77.0", "1.80.1", "1.95"] {
        p("cargo::rustc-cfg=x\n", ok).unwrap();
    }
    for bad in ["1", "1.0", "1.76", "1.76.9", "2", "2.0.0"] {
        let e = p("cargo::rustc-cfg=x\n", bad).unwrap_err().0;
        assert!(
            e.starts_with(&format!(
                "the `cargo::` syntax for build script output instructions was added in Rust 1.77.0, \
                 but the minimum supported Rust version of `ring v0.17.14` is {bad}.\n"
            )),
            "{e}"
        );
    }
    // Suggestions.
    let e = p("cargo::rustc-cfg=x\n", "1.70").unwrap_err().0;
    assert!(
        e.contains("Switch to the old `cargo:rustc-cfg=x` syntax"),
        "{e}"
    );
    let e = p("cargo::metadata=k=v\n", "1.70").unwrap_err().0;
    assert!(
        e.contains("Switch to the old `cargo:k=v` syntax instead of `cargo::metadata=k=v`"),
        "{e}"
    );
    let e = p("cargo::error=x\n", "1.70").unwrap_err().0;
    assert!(!e.contains("Switch"), "{e}");
    // The old syntax is unaffected, and the check runs before key parsing.
    p("cargo:rustc-cfg=x\n", "1.60").unwrap();
    assert!(
        p("cargo::bogus\n", "1.60")
            .unwrap_err()
            .0
            .contains("Rust 1.77.0")
    );
    // Unparseable versions are refused.
    assert!(msrv_allows_new_syntax("1.x").is_err());
    assert!(msrv_allows_new_syntax("").is_err());
    assert!(msrv_allows_new_syntax("1.2.3.4").is_err());
}

#[test]
fn streaming_errors_match_cargo() {
    let m = streamed_log_messages(
        b"cargo::error=a\r\n  cargo::error=indented\ncargo:error=old\ncargo:warning=w1\ncargo::warning=w2\ncargo::error=\xff\ncargo::error=last",
    );
    let got: Vec<_> = m.iter().map(|m| (m.severity, m.message.as_str())).collect();
    assert_eq!(
        got,
        [
            (Severity::Error, "a"),
            (Severity::Warning, "w1"),
            (Severity::Warning, "w2"),
            (Severity::Error, "\u{fffd}"),
            (Severity::Error, "last"),
        ]
    );
    // The indented error is still parsed as an error, but does not fail the
    // run by itself.
    let out = parse_ok("  cargo::error=indented\n");
    assert!(out.has_errors());
}

#[test]
fn envify_and_metadata_env() {
    assert_eq!(envify("ring_core-0.17"), "RING_CORE_0.17");
    assert_eq!(envify("straße"), "STRASSE");
    let m = MetadataFile {
        links: "openssl".into(),
        metadata: kv(&[("include", "/i"), ("version-number", "30000")]),
    };
    assert_eq!(
        m.env(),
        kv(&[
            ("DEP_OPENSSL_INCLUDE", "/i"),
            ("DEP_OPENSSL_VERSION_NUMBER", "30000")
        ])
    );
}

#[test]
fn directives_json_round_trip() {
    let out = parse_ok(
        "cargo::rustc-cfg=a\ncargo::rustc-link-arg-bin=app=x\ncargo::rustc-env=K=V\ncargo::warning=w\n",
    );
    let json = serde_json::to_string(&out).unwrap();
    assert_eq!(serde_json::from_str::<BuildOutput>(&json).unwrap(), out);
    assert!(
        json.contains(r#""linkerArgs":[{"kind":"rustc-link-arg-bin","bin":"app","value":"x"}]"#),
        "{json}"
    );
    assert!(json.contains(r#""env":[["K","V"]]"#), "{json}");
}
