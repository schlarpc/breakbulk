#!/usr/bin/env python3
"""Generate a synthetic breakbulk plan and the matching source trees.

    gen.py --n 1000 --out DIR            # random DAG (default model)
    gen.py --lock Cargo.lock --out DIR   # the dependency topology of a real lockfile
    gen.py --n 1000 --stats              # print graph statistics only

DIR gets:

    plan.json        a build plan in the shape of tests/unit-smoke/plan.json:
                     one compile unit per library crate (a registry-like
                     crate source), a build-script compile and run for a
                     fraction of them, and one bin root (a workspace package
                     `app` depending on every library nobody else depends on).
                     rustc is named by the token `@bb:rustc@`, which the Nix
                     driver replaces with a store path.
    Cargo.toml       a Cargo workspace of the same crates with path
                     dependencies, for the `cargo build` comparison.
    app/, crates/    the sources: tiny crates, one function each.
    stats.json       graph statistics.

The random model is fitted to zed's Cargo.lock (1,655 crates once Windows
and wasm-only crates are dropped): out-degrees are drawn from zed's
empirical out-degree histogram and sorted along the build order with noise
(`--noise`), so low-degree crates sit low in the graph; each edge goes either
to one of the last `--window` crates (probability `--local`, which builds
depth) or to an earlier crate chosen by linear preferential attachment
(weight `--pa` times fan-in, plus one), which gives the heavy-tailed fan-in
of libc, cfg-if, serde and friends. The defaults reproduce zed's
sum-of-closures / N^2 (about 0.08).

What a compile unit gets is what Cargo passes, for the parts that grow with
the graph (verified against Cargo 0.100, src/compiler/custom_build.rs
`build_map::build` and src/compiler/mod.rs `add_native_deps`):

  - one `--extern name=<rmeta>` per direct dependency (`rlib` for the bin);
  - one `-L` per library path printed by the build script of the unit's
    own package or of any transitive (linkable) dependency, in Cargo's
    `to_link` order. A traced plan carries a `rustc-link-search` splice for
    each of those build scripts, because the planner's stubs always print a
    link-search sentinel;
  - its own build script's cfg, check-cfg and env splices, and OUT_DIR.

The transitive rmeta/rlib list (`deps` in BREAKBULK_UNIT) is computed by
breakbulk-format from the `--extern` edges, as for a real plan.
"""

import argparse
import hashlib
import json
import os
import random
import statistics
import sys

TRIPLE = "x86_64-unknown-linux-gnu"
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"
SKELETON = "/build/skeleton"

# zed's Cargo.lock, Windows and wasm crates dropped: out-degree -> count.
ZED_OUT_DEGREES = {
    0: 321, 1: 271, 2: 219, 3: 200, 4: 112, 5: 86, 6: 66, 7: 59, 8: 31, 9: 29,
    10: 24, 11: 23, 12: 14, 13: 17, 14: 13, 15: 13, 16: 18, 17: 13, 18: 12,
    19: 14, 20: 9, 21: 4, 22: 6, 23: 3, 24: 6, 26: 4, 27: 5, 28: 7, 29: 4,
    30: 4, 31: 4, 32: 2, 33: 2, 34: 4, 35: 3, 36: 4, 37: 4, 38: 1, 39: 1,
    44: 1, 46: 1, 48: 2, 49: 1, 50: 2, 51: 1, 55: 1, 56: 1, 58: 1, 60: 1,
    63: 2, 64: 1, 69: 1, 77: 1, 78: 1, 79: 1, 82: 1, 90: 1, 99: 1, 171: 1,
}


# --- graphs ------------------------------------------------------------------


def random_dag(n, seed, local, window, noise, pa):
    """deps[i] is a sorted list of indices < i."""
    rng = random.Random(seed)
    pool = [d for d, c in ZED_OUT_DEGREES.items() for _ in range(c)]
    # Low out-degree crates sit low in the graph: sort the sampled degrees
    # by a noisy rank, so position correlates with degree but not fully.
    degrees = sorted(
        (rng.choice(pool) for _ in range(n)),
    )
    keyed = sorted(range(n), key=lambda r: r + rng.gauss(0, noise * n))
    degrees = [degrees[r] for r in keyed]
    bag = []  # node j appears fanin(j) + 1 times
    deps = []
    for i in range(n):
        want = min(degrees[i], i)
        chosen = set()
        while len(chosen) < want:
            if rng.random() < local:
                j = rng.randrange(max(0, i - window), i)
            else:
                j = rng.choice(bag)
            chosen.add(j)
        bag.extend(list(chosen) * pa)
        bag.append(i)
        deps.append(sorted(chosen))
    return deps


def lock_dag(path, drop_platform=True):
    """The package graph of a Cargo.lock, cycles (from dev-dependencies)
    broken, in topological order."""
    import tomllib

    with open(path, "rb") as f:
        packages = tomllib.load(f)["package"]
    versions = {}
    for p in packages:
        versions.setdefault(p["name"], []).append(p["version"])
    skip = ("windows", "winapi", "wasm", "js-sys", "web-sys", "redox", "hermit", "wasi")
    dropped = lambda k: drop_platform and k.startswith(skip)
    graph = {}
    for p in packages:
        k = f"{p['name']}@{p['version']}"
        if dropped(k):
            continue
        ds = []
        for d in p.get("dependencies", []):
            parts = d.split(" ")
            dk = f"{parts[0]}@{parts[1] if len(parts) > 1 else versions[parts[0]][0]}"
            if not dropped(dk):
                ds.append(dk)
        graph[k] = ds
    order, state = [], {}
    sys.setrecursionlimit(100000)

    def visit(k):
        state[k] = 1
        kept = []
        for d in graph[k]:
            if state.get(d) == 1:
                continue  # back edge: a dev-dependency cycle
            if d not in state:
                visit(d)
            kept.append(d)
        graph[k] = kept
        state[k] = 2
        order.append(k)

    for k in sorted(graph):
        if k not in state:
            visit(k)
    index = {k: i for i, k in enumerate(order)}
    return [sorted(index[d] for d in set(graph[k])) for k in order]


def graph_stats(deps):
    n = len(deps)
    depth = [0] * n
    closure = [None] * n
    for i in range(n):
        c = set()
        for j in deps[i]:
            c |= closure[j]
            c.add(j)
            depth[i] = max(depth[i], depth[j] + 1)
        closure[i] = c
    sizes = [len(c) for c in closure]
    fanin = [0] * n
    for ds in deps:
        for j in ds:
            fanin[j] += 1
    edges = sum(map(len, deps))
    return {
        "crates": n,
        "edges": edges,
        "avgDirectDeps": round(edges / n, 2),
        "maxDepth": max(depth) if n else 0,
        "avgClosure": round(sum(sizes) / n, 1),
        "medianClosure": statistics.median(sizes),
        "sumClosure": sum(sizes),
        "sumClosureOverN2": round(sum(sizes) / n / n, 4),
        "topFanIn": sorted(fanin, reverse=True)[:8],
        "roots": sum(1 for f in fanin if f == 0),
    }, closure


# --- plan ----------------------------------------------------------------------


def h16(*parts):
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:16]


PKG_ENV_EMPTY = [
    "CARGO_PKG_AUTHORS", "CARGO_PKG_DESCRIPTION", "CARGO_PKG_HOMEPAGE",
    "CARGO_PKG_LICENSE", "CARGO_PKG_LICENSE_FILE", "CARGO_PKG_README",
    "CARGO_PKG_REPOSITORY", "CARGO_PKG_RUST_VERSION", "CARGO_PKG_VERSION_PRE",
]

CFG_ENV = {
    "CARGO_CFG_DEBUG_ASSERTIONS": "", "CARGO_CFG_FEATURE": "", "CARGO_CFG_PANIC": "unwind",
    "CARGO_CFG_TARGET_ABI": "", "CARGO_CFG_TARGET_ARCH": "x86_64",
    "CARGO_CFG_TARGET_ENDIAN": "little", "CARGO_CFG_TARGET_ENV": "gnu",
    "CARGO_CFG_TARGET_FAMILY": "unix", "CARGO_CFG_TARGET_FEATURE": "fxsr,sse,sse2",
    "CARGO_CFG_TARGET_HAS_ATOMIC": "16,32,64,8,ptr",
    "CARGO_CFG_TARGET_HAS_ATOMIC_PRIMITIVE_ALIGNMENT": "16,32,64,8,ptr",
    "CARGO_CFG_TARGET_OS": "linux", "CARGO_CFG_TARGET_POINTER_WIDTH": "64",
    "CARGO_CFG_TARGET_VENDOR": "unknown", "CARGO_CFG_UNIX": "", "CARGO_ENCODED_RUSTFLAGS": "",
    "DEBUG": "true", "HOST": TRIPLE, "NUM_JOBS": "8", "OPT_LEVEL": "0", "PROFILE": "debug",
    "RUSTC": "@bb:rustc@", "TARGET": TRIPLE,
}

COMMON_ARGS = [
    "--error-format=json", "--json=diagnostic-rendered-ansi,artifacts,future-incompat",
]


def pkg_env(name, manifest_dir, manifest_path):
    env = {k: "" for k in PKG_ENV_EMPTY}
    env.update({
        "CARGO_MANIFEST_DIR": manifest_dir,
        "CARGO_MANIFEST_PATH": manifest_path,
        "CARGO_PKG_NAME": name,
        "CARGO_PKG_VERSION": "0.1.0",
        "CARGO_PKG_VERSION_MAJOR": "0",
        "CARGO_PKG_VERSION_MINOR": "1",
        "CARGO_PKG_VERSION_PATCH": "0",
    })
    return env


def make_plan(deps, names, has_script, app_deps):
    units = {}
    n = len(deps)
    pkg = [f"{REGISTRY}#{names[i]}@0.1.0" for i in range(n)]
    lib_id = [f"c-{h16('lib', names[i])}" for i in range(n)]
    extra = [h16("extra", names[i]) for i in range(n)]
    run_id = [f"r-{names[i]}-{h16('run', names[i])}" if has_script[i] else None for i in range(n)]

    # Cargo's to_link: own script first, then each dependency's to_link in
    # package-id order, without duplicates.
    to_link = []
    for i in range(n):
        seen, out = set(), []
        if has_script[i]:
            out.append(i)
            seen.add(i)
        for j in sorted(deps[i], key=lambda j: pkg[j]):
            for k in to_link[j]:
                if k not in seen:
                    seen.add(k)
                    out.append(k)
        to_link.append(out)

    def src(i, rel):
        return [{"crateSrc": pkg[i], "rel": rel}]

    def lib_file(i, kind):
        return f"lib{names[i]}-{extra[i]}.{kind}"

    for i in range(n):
        name = names[i]
        args = [
            "--crate-name", name, "--edition=2021", src(i, "src/lib.rs"), *COMMON_ARGS,
            "--crate-type", "lib", "--emit=dep-info,metadata,link", "-C", "embed-bitcode=no",
            "-C", "debuginfo=2", "--check-cfg", "cfg(docsrs,test)",
            "--check-cfg", "cfg(feature, values())",
            "-C", f"metadata={lib_id[i][2:]}", "-C", f"extra-filename=-{extra[i]}",
            "--target", TRIPLE,
        ]
        for j in sorted(deps[i], key=lambda j: names[j]):
            args += ["--extern", [f"{names[j]}=", {"out": lib_id[j], "output": "rmeta", "file": lib_file(j, "rmeta")}]]
        args += ["--cap-lints", "allow"]
        for k in to_link[i]:
            args.append({"splice": run_id[k], "kind": "rustc-link-search"})
        env = pkg_env(name, src(i, ""), src(i, "Cargo.toml"))
        env["CARGO_CRATE_NAME"] = name
        env_splices = []
        if has_script[i]:
            args.append({"splice": run_id[i], "kind": "rustc-cfg"})
            args.append({"splice": run_id[i], "kind": "rustc-check-cfg"})
            env["OUT_DIR"] = [{"out": run_id[i], "output": "out"}]
            env_splices.append({"splice": run_id[i], "kind": "rustc-env"})
        units[lib_id[i]] = {
            "kind": "compile",
            "package": pkg[i],
            "crate": {"name": name, "types": ["lib"], "edition": "2021"},
            "platform": "target",
            "program": ["@bb:rustc@"],
            "args": args,
            "env": env,
            "envSplices": env_splices,
            "cwd": {"crateSrc": pkg[i], "rel": ""},
            "outputs": {"rmeta": [lib_file(i, "rmeta")], "rlib": [lib_file(i, "rlib")]},
        }
        if has_script[i]:
            bs_id = f"c-{h16('bs', name)}"
            bs_extra = h16("bs-extra", name)
            benv = pkg_env(name, src(i, ""), src(i, "Cargo.toml"))
            benv["CARGO_CRATE_NAME"] = "build_script_build"
            units[bs_id] = {
                "kind": "compile",
                "package": pkg[i],
                "crate": {"name": "build_script_build", "types": ["bin"], "edition": "2021"},
                "platform": "host",
                "program": ["@bb:rustc@"],
                "args": [
                    "--crate-name", "build_script_build", "--edition=2021", src(i, "build.rs"),
                    *COMMON_ARGS, "--crate-type", "bin", "--emit=dep-info,link",
                    "-C", "embed-bitcode=no", "-C", "debuginfo=2",
                    "--check-cfg", "cfg(docsrs,test)", "--check-cfg", "cfg(feature, values())",
                    "-C", f"metadata={bs_id[2:]}", "-C", f"extra-filename=-{bs_extra}",
                    "--cap-lints", "allow",
                ],
                "env": benv,
                "envSplices": [],
                "cwd": {"crateSrc": pkg[i], "rel": ""},
                "outputs": {"bin": [f"build_script_build-{bs_extra}"]},
            }
            renv = pkg_env(name, src(i, ""), src(i, "Cargo.toml"))
            renv.update(CFG_ENV)
            renv["OUT_DIR"] = [{"out": run_id[i], "output": "out"}]
            units[run_id[i]] = {
                "kind": "run",
                "package": pkg[i],
                "platform": "target",
                "script": {"out": bs_id, "output": "bin", "file": f"build_script_build-{bs_extra}"},
                "env": renv,
                "cwd": {"crateSrc": pkg[i], "rel": ""},
                "metadataFrom": [],
                "targets": [
                    {"name": "build-script-build", "kind": ["custom-build"]},
                    {"name": name, "kind": ["lib"]},
                ],
                "nightlyFeaturesAllowed": False,
            }

    # The bin root: a workspace package.
    app_pkg = f"path+file://{SKELETON}/app#0.1.0"
    app_id = f"c-{h16('app')}"
    app_extra = h16("app-extra")
    app_src = lambda rel: [{"src": app_pkg, "rel": rel}]
    args = [
        "--crate-name", "app", "--edition=2021", "app/src/main.rs", *COMMON_ARGS,
        "--crate-type", "bin", "--emit=dep-info,link", "-C", "embed-bitcode=no",
        "-C", "debuginfo=2", "--check-cfg", "cfg(docsrs,test)",
        "--check-cfg", "cfg(feature, values())",
        "-C", f"metadata={app_id[2:]}", "-C", f"extra-filename=-{app_extra}",
        "--target", TRIPLE,
    ]
    for j in sorted(app_deps, key=lambda j: names[j]):
        args += ["--extern", [f"{names[j]}=", {"out": lib_id[j], "output": "rlib", "file": lib_file(j, "rlib")}]]
    seen, app_link = set(), []
    for j in sorted(app_deps, key=lambda j: pkg[j]):
        for k in to_link[j]:
            if k not in seen:
                seen.add(k)
                app_link.append(k)
    for k in app_link:
        args.append({"splice": run_id[k], "kind": "rustc-link-search"})
    env = pkg_env("app", app_src("app"), app_src("app/Cargo.toml"))
    env.update({"CARGO_BIN_NAME": "app", "CARGO_CRATE_NAME": "app", "CARGO_PRIMARY_PACKAGE": "1"})
    units[app_id] = {
        "kind": "compile",
        "package": app_pkg,
        "crate": {"name": "app", "types": ["bin"], "edition": "2021"},
        "platform": "target",
        "program": ["@bb:rustc@"],
        "args": args,
        "env": env,
        "envSplices": [],
        "cwd": {"src": app_pkg, "rel": ""},
        "outputs": {"bin": [f"app-{app_extra}"]},
    }
    return {
        "version": 1,
        "kind": "build",
        "cargo": "1.99.0",
        "rustc": "1.99.0",
        "host": TRIPLE,
        "target": TRIPLE,
        "variant": {"profile": "dev", "features": [], "mode": "build"},
        "skeletonRoot": SKELETON,
        "trimPaths": False,
        "units": dict(sorted(units.items())),
        "roots": [{"package": app_pkg, "target": "app", "kind": "bin", "unit": app_id, "test": False}],
    }, pkg


# --- sources -------------------------------------------------------------------


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def write_sources(out, deps, names, has_script, app_deps):
    members = ["app"]
    for i, name in enumerate(names):
        d = f"{out}/crates/{name}"
        members.append(f"crates/{name}")
        dep_lines = "".join(f'{names[j]} = {{ path = "../{names[j]}" }}\n' for j in deps[i])
        build = 'build = "build.rs"\n' if has_script[i] else ""
        write(f"{d}/Cargo.toml",
              f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2021"\n{build}\n'
              f"[dependencies]\n{dep_lines}")
        body = " + ".join([f"{i}"] + [f"{names[j]}::f()" for j in deps[i]])
        lib = f"pub fn f() -> u64 {{ {i} }}\n\npub fn sum() -> u64 {{\n    {body}\n}}\n"
        if has_script[i]:
            lib += "\n#[cfg(bb_built)]\npub const BUILT: bool = true;\n"
            write(f"{d}/build.rs",
                  'fn main() {\n    println!("cargo::rustc-check-cfg=cfg(bb_built)");\n'
                  '    println!("cargo::rustc-cfg=bb_built");\n}\n')
        write(f"{d}/src/lib.rs", lib)
    dep_lines = "".join(f'{names[j]} = {{ path = "../crates/{names[j]}" }}\n' for j in app_deps)
    write(f"{out}/app/Cargo.toml",
          f'[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n{dep_lines}')
    body = "\n".join(f"    t = t.wrapping_add({names[j]}::sum());" for j in app_deps)
    write(f"{out}/app/src/main.rs",
          f"fn main() {{\n    let mut t: u64 = 0;\n{body}\n    println!(\"scale ok: {{t}}\");\n}}\n")
    write(f"{out}/Cargo.toml",
          '[workspace]\nresolver = "2"\nmembers = ["app", "crates/*"]\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, help="number of library crates (random model)")
    ap.add_argument("--lock", help="take the graph from this Cargo.lock instead")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--local", type=float, default=0.12, help="probability an edge goes to a recent crate")
    ap.add_argument("--window", type=int, default=30, help="how recent")
    ap.add_argument("--pa", type=int, default=3, help="weight of fan-in in preferential attachment")
    ap.add_argument("--noise", type=float, default=0.15, help="how loosely out-degree follows position")
    ap.add_argument("--build-scripts", type=float, default=0.12, help="fraction of crates with a build script")
    ap.add_argument("--out")
    ap.add_argument("--stats", action="store_true", help="print graph statistics and exit")
    a = ap.parse_args()
    if a.lock:
        deps = lock_dag(a.lock)
        model = {"model": "lock", "lock": os.path.basename(a.lock)}
    elif a.n:
        deps = random_dag(a.n, a.seed, a.local, a.window, a.noise, a.pa)
        model = {"model": "random", "seed": a.seed, "local": a.local, "window": a.window, "noise": a.noise, "pa": a.pa}
    else:
        ap.error("--n or --lock")
    stats, _ = graph_stats(deps)
    stats.update(model)
    n = len(deps)
    rng = random.Random(a.seed + 1)
    has_script = [rng.random() < a.build_scripts for _ in range(n)]
    stats["buildScripts"] = sum(has_script)
    if a.stats or not a.out:
        print(json.dumps(stats))
        return
    names = [f"bb{i:05}" for i in range(n)]
    depended = {j for ds in deps for j in ds}
    app_deps = [i for i in range(n) if i not in depended]
    plan, _ = make_plan(deps, names, has_script, app_deps)
    stats["units"] = len(plan["units"])
    stats["appDirectDeps"] = len(app_deps)
    write_sources(a.out, deps, names, has_script, app_deps)
    with open(f"{a.out}/plan.json", "w") as f:
        json.dump(plan, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(f"{a.out}/stats.json", "w") as f:
        json.dump(stats, f, indent=1, sort_keys=True)
        f.write("\n")
    print(json.dumps(stats))


if __name__ == "__main__":
    main()
