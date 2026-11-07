use super::*;

fn outer(vars: &[(&str, &str)]) -> Outer {
    Outer {
        vars: vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
    }
}

fn map(vars: &[(&str, &str)]) -> BTreeMap<String, String> {
    vars.iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn none() -> CFlags {
    CFlags::default()
}

#[test]
fn nothing_leaks_from_the_builder() {
    let o = outer(&[
        ("TMPDIR", "/build"),
        ("NIX_BUILD_CORES", "4"),
        ("NIX_BUILD_TOP", "/build"),
        ("NIX_STORE", "/nix/store"),
        ("PATH", "/outer/bin"),
        ("out", "/nix/store/x-out"),
        ("BREAKBULK_UNIT", "{}"),
        ("HOME", "/home/me"),
        ("SOURCE_DATE_EPOCH", "1"),
        ("NIX_CFLAGS_COMPILE", "-DOUTER"),
    ]);
    let env = layered(&o, None, &BTreeMap::new(), &none());
    assert_eq!(
        env,
        map(&[
            ("HOME", "/homeless-shelter"),
            ("LC_ALL", "C"),
            ("NIX_BUILD_CORES", "4"),
            ("NIX_BUILD_TOP", "/build"),
            ("NIX_STORE", "/nix/store"),
            ("SOURCE_DATE_EPOCH", "315532800"),
            ("TMPDIR", "/build"),
            ("TZ", "UTC"),
        ])
    );
}

#[test]
fn later_layers_win() {
    let o = outer(&[("TMPDIR", "/build")]);
    let capture = map(&[("CC", "gcc"), ("TZ", "Europe/Paris")]);
    let unit = map(&[
        ("CC", "clang"),
        ("CARGO_PKG_NAME", "x"),
        ("SOURCE_DATE_EPOCH", "1700000000"),
    ]);
    let env = layered(&o, Some(&capture), &unit, &none());
    assert_eq!(env["CC"], "clang");
    assert_eq!(env["TZ"], "Europe/Paris");
    assert_eq!(env["CARGO_PKG_NAME"], "x");
    assert_eq!(env["HOME"], "/homeless-shelter");
    // A package's build stamp replaces the base's epoch.
    assert_eq!(env["SOURCE_DATE_EPOCH"], "1700000000");
}

#[test]
fn list_like_variables() {
    for (name, sep) in [
        ("PATH", Some(':')),
        ("PKG_CONFIG_PATH", Some(':')),
        ("PKG_CONFIG_PATH_FOR_BUILD", Some(':')),
        ("XDG_DATA_DIRS", Some(':')),
        ("CMAKE_LIBRARY_PATH", Some(':')),
        ("NIX_CFLAGS_COMPILE", Some(' ')),
        ("NIX_CFLAGS_COMPILE_FOR_BUILD", Some(' ')),
        ("NIX_LDFLAGS", Some(' ')),
        ("NIX_CFLAGS_LINK", Some(' ')),
        ("BINDGEN_EXTRA_CLANG_ARGS", Some(' ')),
        // Replaced, not appended.
        ("CC", None),
        ("PKG_CONFIG", None),
        ("CFLAGS", None),
        ("LD_LIBRARY_PATH", None),
        ("NIX_HARDENING_ENABLE", None),
        ("BINDGEN_EXTRA_CLANG_ARGS_x86_64_unknown_linux_gnu", None),
        ("_FOR_BUILD", None),
    ] {
        assert_eq!(list_separator(name), sep, "{name}");
    }
}

#[test]
fn list_like_variables_append_across_layers() {
    let o = outer(&[]);
    let capture = map(&[
        ("PATH", "/cap/bin"),
        ("NIX_CFLAGS_COMPILE", " -isystem /cap/include"),
        ("NIX_LDFLAGS", " -L/cap/lib"),
        ("PKG_CONFIG_PATH", "/cap/lib/pkgconfig"),
    ]);
    let unit = map(&[
        ("PATH", "/spec/bin"),
        ("NIX_CFLAGS_COMPILE", "-DSPEC"),
        ("NIX_LDFLAGS", "-L/spec/lib"),
        ("BINDGEN_EXTRA_CLANG_ARGS", "-I/spec/include"),
    ]);
    let env = layered(&o, Some(&capture), &unit, &none());
    assert_eq!(env["PATH"], "/cap/bin:/spec/bin");
    assert_eq!(env["NIX_CFLAGS_COMPILE"], " -isystem /cap/include -DSPEC");
    assert_eq!(env["NIX_LDFLAGS"], " -L/cap/lib -L/spec/lib");
    assert_eq!(env["PKG_CONFIG_PATH"], "/cap/lib/pkgconfig");
    // No earlier value: the later one as is.
    assert_eq!(env["BINDGEN_EXTRA_CLANG_ARGS"], "-I/spec/include");
}

#[test]
fn merge_layer_merges_spec_and_override_layers() {
    // Layers 3, 4, 5, as instantiation merges them.
    let mut env = map(&[("CARGO_PKG_NAME", "x"), ("PATH", "")]);
    merge_layer(&mut env, [("PATH", "/spec/bin"), ("CC", "spec-cc")]);
    merge_layer(&mut env, [("PATH", "/override/bin"), ("CC", "override-cc")]);
    merge_layer(&mut env, [("PATH", "")]);
    // Empty values add no empty search-path entry.
    assert_eq!(env["PATH"], "/spec/bin:/override/bin");
    assert_eq!(env["CC"], "override-cc");
}

#[test]
fn append_skips_empty_sides() {
    assert_eq!(append(':', "", "/b"), "/b");
    assert_eq!(append(':', "/a", ""), "/a");
    assert_eq!(append(':', "", ""), "");
    assert_eq!(append(' ', "-a", "-b"), "-a -b");
}

#[test]
fn c_flags_seed_first_prefix_maps_last() {
    let o = outer(&[]);
    let capture = map(&[("NIX_CFLAGS_COMPILE", " -isystem /cap/include")]);
    let unit = map(&[("NIX_CFLAGS_COMPILE", "-DOVERRIDE")]);
    let cflags = CFlags {
        random_seed: Some("0123456789".into()),
        prefix_maps: vec![
            ("/nix/store/s-ring-0.17.14".into(), "ring-0.17.14".into()),
            ("/nix/store/o-out".into(), "/breakbulk/build/r-ring".into()),
        ],
    };
    let env = layered(&o, Some(&capture), &unit, &cflags);
    assert_eq!(
        env["NIX_CFLAGS_COMPILE"],
        " -frandom-seed=0123456789 -isystem /cap/include -DOVERRIDE \
         -ffile-prefix-map=/nix/store/s-ring-0.17.14=ring-0.17.14 \
         -ffile-prefix-map=/nix/store/o-out=/breakbulk/build/r-ring"
    );

    // With the base capture's empty value: the seed alone, where stdenv puts
    // it (reproducible-builds.sh appends to an empty variable).
    let env = layered(
        &o,
        Some(&map(&[("NIX_CFLAGS_COMPILE", "")])),
        &BTreeMap::new(),
        &CFlags {
            random_seed: Some("s".into()),
            prefix_maps: vec![],
        },
    );
    assert_eq!(env["NIX_CFLAGS_COMPILE"], " -frandom-seed=s");

    // Nothing to add: the variable is left alone (and not created).
    let env = layered(&o, None, &BTreeMap::new(), &none());
    assert!(!env.contains_key("NIX_CFLAGS_COMPILE"));
}

#[test]
fn seed_is_its_own_word_before_a_value_without_leading_space() {
    // The base capture's empty value, then a package override's flag: the
    // merged value has no leading space, and the seed must not run into it.
    let env = layered(
        &outer(&[]),
        Some(&map(&[("NIX_CFLAGS_COMPILE", "")])),
        &map(&[("NIX_CFLAGS_COMPILE", "-DSTAMP=1")]),
        &CFlags {
            random_seed: Some("s".into()),
            prefix_maps: vec![],
        },
    );
    assert_eq!(env["NIX_CFLAGS_COMPILE"], " -frandom-seed=s -DSTAMP=1");
}

#[test]
fn prefix_maps_that_cannot_be_words_are_skipped() {
    let c = CFlags {
        random_seed: None,
        prefix_maps: vec![
            ("/nix/store/a".into(), "my crate".into()),
            ("".into(), "x".into()),
            ("/nix/store/b".into(), ".".into()),
        ],
    };
    assert_eq!(c.prefix_map_flags(), ["-ffile-prefix-map=/nix/store/b=."]);
}

#[test]
fn num_jobs_follows_nix_build_cores() {
    let o = outer(&[("NIX_BUILD_CORES", "3")]);
    let env = layered(&o, None, &map(&[("NUM_JOBS", "8")]), &none());
    assert_eq!(env["NUM_JOBS"], "3");
    // Only units that have NUM_JOBS (build-script runs) get it.
    assert!(!layered(&o, None, &BTreeMap::new(), &none()).contains_key("NUM_JOBS"));
    // 0 means every CPU.
    let o = outer(&[("NIX_BUILD_CORES", "0")]);
    let n: usize = layered(&o, None, &map(&[("NUM_JOBS", "8")]), &none())["NUM_JOBS"]
        .parse()
        .unwrap();
    assert!(n >= 1);
}

#[test]
fn outputs_and_tmpdir() {
    let o = outer(&[("rlib", "/nix/store/x-rlib"), ("TMPDIR", "")]);
    assert_eq!(
        o.output("rlib").unwrap(),
        PathBuf::from("/nix/store/x-rlib")
    );
    assert!(
        o.output("rmeta")
            .unwrap_err()
            .to_string()
            .contains("`rmeta`")
    );
    assert_eq!(o.tmpdir(), PathBuf::from("/tmp"));
}

#[test]
fn captures_are_read_from_the_file_or_the_output() {
    let t = crate::test_util::TempDir::new("capture");
    let json = t.path().join("env.json");
    std::fs::write(&json, r#"{"CC":"gcc","PATH":"/p/bin"}"#).unwrap();
    let want = map(&[("CC", "gcc"), ("PATH", "/p/bin")]);
    assert_eq!(read_capture(&json).unwrap(), want);
    assert_eq!(read_capture(t.path()).unwrap(), want);
    std::fs::write(&json, r#"{"CC":1}"#).unwrap();
    assert!(
        read_capture(t.path())
            .unwrap_err()
            .0
            .contains("not a JSON object of strings")
    );
}
