"""Generate a random Cargo workspace for the directive differential test.

    python3 gen.py --seed N --out DIR [--triple T]

Every package is a path crate in one workspace (no registry, no network).
The graph has normal dependencies, build dependencies, dev-dependencies,
proc macros and `links` chains. Each build script prints a fixed, shuffled
list of directives chosen here: several values per kind, duplicates,
link-search paths inside and outside OUT_DIR (and inside a links
dependency's OUT_DIR, through DEP_<LINKS>_ROOT), both syntaxes, and
`rustc-flags`. Sometimes `.cargo/config.toml` overrides a `links` package's
build script. Values are chosen so a real `cargo build` and `cargo test
--no-run` link: libraries exist (libm, libdl, or an empty archive the
script writes), link arguments are harmless.

Writes DIR/<package>/... and DIR/Cargo.toml, and prints a summary.
"""

import argparse
import json
import random
from pathlib import Path

LINK_ARGS = ["-Wl,-O1", "-Wl,-znoexecstack", "-Wl,-zrelro", "-Wl,--sort-common"]
EXTERNAL_DIRS = ["/nonexistent/bb-a", "/nonexistent/bb-b", "/usr/lib/bb-c"]


class Pkg:
    def __init__(self, i, rng):
        self.i = i
        self.name = f"p{i}"
        self.proc_macro = False
        self.cdylib = False
        self.bins = []
        self.test = False
        self.example = False
        self.bench = False
        self.build_script = False
        self.links = None
        self.old_syntax = False
        self.deps = []  # (pkg, kind) with kind in normal|build|dev
        self.lines = []


def gen(seed, triple):
    rng = random.Random(seed)
    n = rng.randint(3, 7)
    pkgs = [Pkg(i, rng) for i in range(n)]
    for p in pkgs:
        p.proc_macro = p.i < n - 1 and rng.random() < 0.2
        p.cdylib = not p.proc_macro and rng.random() < 0.2
        if not p.proc_macro:
            if rng.random() < 0.4 or p.i == n - 1:
                p.bins = [p.name] + ([f"{p.name}-tool"] if rng.random() < 0.3 else [])
            p.test = rng.random() < 0.4
            p.example = rng.random() < 0.3
            p.bench = rng.random() < 0.2
        p.build_script = rng.random() < 0.8
        if p.build_script and rng.random() < 0.5:
            p.links = f"l{p.i}"
        # Old syntax: `cargo:` only, and an MSRV before 1.77.
        p.old_syntax = rng.random() < 0.25
        for j in range(p.i):
            q = pkgs[j]
            r = rng.random()
            if r < 0.35:
                p.deps.append((q, "normal"))
            elif r < 0.5 and not q.proc_macro:
                p.deps.append((q, "build"))
            elif r < 0.6 and not q.proc_macro:
                p.deps.append((q, "dev"))
    # Links packages overridden in config: their build scripts never run.
    overridden = [p for p in pkgs if p.links and rng.random() < 0.3]
    for p in pkgs:
        if p.build_script:
            p.lines = directives(p, rng, overridden)
    return pkgs, overridden


def directives(p, rng, overridden):
    """Templates: @OUT@ is OUT_DIR, @DEP:<VAR>@ another env var's value."""
    out = []
    links_deps = [q for q, k in p.deps if k == "normal" and q.links]

    def add(kind, value, k=1):
        for _ in range(k):
            out.append((kind, value))

    for _ in range(rng.randint(0, 3)):
        add("rustc-cfg", rng.choice([f"bb_{p.name}_c{rng.randint(0, 2)}", f'bb_kv="{rng.choice("ab")}"']))
    for _ in range(rng.randint(0, 2)):
        add("rustc-check-cfg", rng.choice([f"cfg(bb_{p.name}_c{rng.randint(0, 2)})", 'cfg(bb_kv, values("a", "b"))']))
    for _ in range(rng.randint(0, 3)):
        add("rustc-env", f"BB_ENV_{rng.randint(0, 2)}={rng.choice(['x', 'a=b', '', p.name])}")
    inside = ["native=@OUT@/lib", "@OUT@", "all=@OUT@/x", "native=@OUT@/a/../b", "dependency=@OUT@/d"]
    outside = [rng.choice(EXTERNAL_DIRS), "native=" + rng.choice(EXTERNAL_DIRS), "framework=/nonexistent/fw", "crate=/nonexistent/crate", "native=relative/dir"]
    outside += [f"native=@DEP:DEP_{q.links.upper()}_ROOT@/lib" for q in links_deps]
    for _ in range(rng.randint(0, 5)):
        add("rustc-link-search", rng.choice(inside if rng.random() < 0.5 else outside), rng.choice([1, 1, 2]))
    static = rng.random() < 0.3
    if static:
        add("rustc-link-search", "native=@OUT@/lib")
        add("rustc-link-lib", f"static=bbstub_{p.name}")
    for _ in range(rng.randint(0, 3)):
        add("rustc-link-lib", rng.choice(["m", "dylib=m", "dl", "dylib=dl"]), rng.choice([1, 1, 2]))
    for _ in range(rng.randint(0, 2)):
        add("rustc-flags", rng.choice(["-l m", "-lm -L native=/nonexistent/flags", "-L @OUT@/flags -l dylib=dl", "-l dl -L@OUT@"]))
    kinds = ["rustc-link-arg"]
    if p.bins:
        kinds.append("rustc-link-arg-bins")
        kinds += [f"rustc-link-arg-bin={b}=" for b in p.bins]
    if p.test:
        kinds.append("rustc-link-arg-tests")
    if p.example:
        kinds.append("rustc-link-arg-examples")
    if p.bench:
        kinds.append("rustc-link-arg-benches")
    if p.cdylib or rng.random() < 0.2:
        # Also from a package without a cdylib: Cargo warns and passes it to
        # dependents' cdylibs (rust-lang/cargo#9562).
        kinds.append(rng.choice(["rustc-link-arg-cdylib", "rustc-cdylib-link-arg"]))
    for _ in range(rng.randint(0, 5)):
        k = rng.choice(kinds)
        v = rng.choice(LINK_ARGS + [f"-Wl,--defsym=bb_{p.name}_{rng.randint(0, 3)}=0"])
        if k.endswith("="):
            # rustc-link-arg-bin=NAME=ARG
            kind, name, _ = k.split("=")
            add(kind, f"{name}={v}")
        else:
            add(k, v)
    if p.links:
        add("metadata", "root=@OUT@")
        for _ in range(rng.randint(0, 2)):
            add("metadata", f"key{rng.randint(0, 1)}=v{rng.randint(0, 9)}")
    if rng.random() < 0.3:
        add("warning", f"hello from {p.name}")
    add("rerun-if-changed", "build.rs")
    rng.shuffle(out)
    lines = []
    for kind, value in out:
        new = not p.old_syntax and rng.random() < 0.5
        if kind == "metadata":
            lines.append(f"cargo::metadata={value}" if new else f"cargo:{value}")
        else:
            lines.append(f"cargo{'::' if new else ':'}{kind}={value}")
        if rng.random() < 0.1:
            lines.append("not a directive")
    return lines


def build_rs(p):
    templates = ",\n    ".join(json.dumps(line) for line in p.lines)
    return f"""// Generated by tests/differential/gen.py.
const LINES: &[&str] = &[
    {templates}
];

fn main() {{
    let out = std::env::var("OUT_DIR").unwrap();
    std::fs::create_dir_all(format!("{{out}}/lib")).unwrap();
    // An empty archive, for `static=bbstub_<pkg>`.
    std::fs::write(format!("{{out}}/lib/libbbstub_{p.name}.a"), b"!<arch>\\n").unwrap();
    for line in LINES {{
        let mut l = line.replace("@OUT@", &out);
        while let Some(s) = l.find("@DEP:") {{
            let e = s + 5 + l[s + 5..].find('@').unwrap();
            let var = &l[s + 5..e];
            let v = std::env::var(var).unwrap_or_else(|_| "/nonexistent/unset".into());
            l = format!("{{}}{{}}{{}}", &l[..s], v, &l[e + 1..]);
        }}
        println!("{{l}}");
    }}
}}
"""


def write(pkgs, overridden, out, triple):
    out.mkdir(parents=True, exist_ok=True)
    members = [p.name for p in pkgs]
    (out / "Cargo.toml").write_text(
        "[workspace]\nresolver = \"2\"\nmembers = [" + ", ".join(json.dumps(m) for m in members) + "]\n"
    )
    for p in pkgs:
        d = out / p.name
        (d / "src").mkdir(parents=True, exist_ok=True)
        m = ["[package]", f'name = "{p.name}"', 'version = "0.1.0"', 'edition = "2021"']
        if p.old_syntax:
            m.append('rust-version = "1.70"')
        if p.links:
            m.append(f'links = "{p.links}"')
        if not p.build_script:
            m.append("build = false")
        m.append("")
        m.append("[lib]")
        if p.proc_macro:
            m.append("proc-macro = true")
        elif p.cdylib:
            m.append('crate-type = ["rlib", "cdylib"]')
        for b in p.bins:
            m += ["", "[[bin]]", f'name = "{b}"', f'path = "src/bin/{b}.rs"']
            (d / "src/bin").mkdir(exist_ok=True)
            (d / f"src/bin/{b}.rs").write_text("fn main() {}\n")
        if p.bench:
            m += ["", "[[bench]]", 'name = "b"', "harness = false"]
            (d / "benches").mkdir(exist_ok=True)
            (d / "benches/b.rs").write_text("fn main() {}\n")
        if p.test:
            (d / "tests").mkdir(exist_ok=True)
            (d / "tests/t.rs").write_text("#[test]\nfn t() {}\n")
        if p.example:
            (d / "examples").mkdir(exist_ok=True)
            (d / "examples/e.rs").write_text("fn main() {}\n")
        for kind, table in (("normal", "dependencies"), ("build", "build-dependencies"), ("dev", "dev-dependencies")):
            ds = [q for q, k in p.deps if k == kind]
            if ds:
                m += ["", f"[{table}]"] + [f'{q.name} = {{ path = "../{q.name}" }}' for q in ds]
        (d / "Cargo.toml").write_text("\n".join(m) + "\n")
        if p.proc_macro:
            lib = "extern crate proc_macro;\nuse proc_macro::TokenStream;\n\n#[proc_macro]\npub fn m(_: TokenStream) -> TokenStream {\n    TokenStream::new()\n}\n"
        else:
            lib = "/// ```\n/// assert_eq!(1, 1);\n/// ```\npub fn f() {}\n"
        (d / "src/lib.rs").write_text(lib)
        if p.build_script:
            (d / "build.rs").write_text(build_rs(p))
    if overridden:
        c = []
        for p in overridden:
            c.append(f"[target.{triple}.{p.links}]")
            c.append('rustc-link-lib = ["m", "dylib=dl"]')
            c.append(f'rustc-link-search = ["/nonexistent/ovr-{p.name}", "native=/nonexistent/ovr2"]')
            c.append('rustc-flags = "-l m -L /nonexistent/ovr-flags"')
            c.append(f'rustc-cfg = ["bb_ovr_{p.name}"]')
            c.append(f'rustc-env = {{ BB_OVR = "{p.name}" }}')
            c.append('rustc-link-arg = ["-Wl,-O1"]')
            c.append(f'root = "/nonexistent/ovr-root-{p.name}"')
            c.append("")
        (out / ".cargo").mkdir(exist_ok=True)
        (out / ".cargo/config.toml").write_text("\n".join(c))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--triple", default="x86_64-unknown-linux-gnu")
    a = ap.parse_args()
    pkgs, overridden = gen(a.seed, a.triple)
    write(pkgs, overridden, a.out, a.triple)
    for p in pkgs:
        deps = ", ".join(f"{q.name}({k})" for q, k in p.deps)
        flags = [x for x, on in (("proc-macro", p.proc_macro), ("cdylib", p.cdylib), ("old-syntax", p.old_syntax), ("overridden", p in overridden)) if on]
        print(f"seed {a.seed}: {p.name} links={p.links} build.rs={p.build_script} bins={p.bins} test={p.test} example={p.example} bench={p.bench} {' '.join(flags)} deps=[{deps}] directives={len(p.lines)}")


if __name__ == "__main__":
    main()
