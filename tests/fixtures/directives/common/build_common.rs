// Shared by every build script in this fixture (pulled in with `include!`).
//
// Prints one or more real values of every directive kind that applies to the
// package, in a deliberately mixed order, so the trace comparison can check
// that splicing sentinel positions reproduces Cargo's real argv exactly.
// Values are harmless for a real link: `-lm`, `--defsym` link args, and
// search paths that exist.

#[allow(dead_code)]
pub struct Pkg<'a> {
    pub name: &'a str,
    pub old_syntax: bool,
    pub links: bool,
    pub bins: &'a [&'a str],
    pub tests: bool,
    pub examples: bool,
    pub benches: bool,
    pub cdylib: bool,
    pub link_lib: bool,
}

pub fn emit(p: &Pkg) {
    let n = p.name.replace('-', "_");
    let up = n.to_uppercase();
    let pre = if p.old_syntax { "cargo:" } else { "cargo::" };
    let out_dir = std::env::var("OUT_DIR").unwrap();
    let inside = format!("{out_dir}/real_search");
    let inside2 = format!("{out_dir}/real_search_flags");
    let external = format!("/tmp/bb-external-{n}");
    std::fs::create_dir_all(&inside).unwrap();
    std::fs::create_dir_all(&inside2).unwrap();

    // Show what Cargo gave us, for the notes.
    let mut deps: Vec<(String, String)> =
        std::env::vars().filter(|(k, _)| k.starts_with("DEP_")).collect();
    deps.sort();
    for (k, v) in &deps {
        eprintln!("{} saw {k}={v}", p.name);
    }

    println!("{pre}rerun-if-changed=build.rs");
    println!("{pre}rustc-cfg=real_{n}_cfg");
    println!("{pre}rustc-check-cfg=cfg(real_{n}_cfg)");
    println!("{pre}rustc-env=REAL_{up}_ENV={n}");
    // External before inside: Cargo moves paths inside OUT_DIR first.
    println!("{pre}rustc-link-search=native={external}");
    println!("{pre}rustc-link-search=native={inside}");
    if p.link_lib {
        println!("{pre}rustc-link-lib=m");
        println!("{pre}rustc-flags=-l dylib=m -L native={inside2}");
    } else {
        println!("{pre}rustc-flags=-L native={inside2}");
    }
    println!("{pre}rustc-cfg=real_{n}_cfg2");
    println!("{pre}rustc-check-cfg=cfg(real_{n}_cfg2)");
    // Link args of several kinds, interleaved.
    if !p.bins.is_empty() {
        println!("{pre}rustc-link-arg-bins=-Wl,--defsym=real_{n}_bins=0");
    }
    println!("{pre}rustc-link-arg=-Wl,--defsym=real_{n}_arg=0");
    for b in p.bins {
        let bu = b.replace('-', "_");
        println!("{pre}rustc-link-arg-bin={b}=-Wl,--defsym=real_{n}_bin_{bu}=0");
    }
    if p.tests {
        println!("{pre}rustc-link-arg-tests=-Wl,--defsym=real_{n}_tests=0");
    }
    if p.examples {
        println!("{pre}rustc-link-arg-examples=-Wl,--defsym=real_{n}_examples=0");
    }
    if p.benches {
        println!("{pre}rustc-link-arg-benches=-Wl,--defsym=real_{n}_benches=0");
    }
    if p.cdylib {
        println!("{pre}rustc-link-arg-cdylib=-Wl,--defsym=real_{n}_cdylib=0");
    }
    println!("{pre}rustc-link-arg=-Wl,--defsym=real_{n}_arg2=0");
    println!("{pre}rustc-env=REAL_{up}_ENV2={n}");
    if p.links {
        if p.old_syntax {
            println!("cargo:key=val_{n}");
            println!("cargo:other=other_{n}");
        } else {
            println!("cargo::metadata=key=val_{n}");
            println!("cargo::metadata=other=other_{n}");
        }
    }
}
