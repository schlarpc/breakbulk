"""Experiment: what changes a unit's `-C metadata` / `-C extra-filename`?

Compares traced units of the directives fixture between a baseline build and
variants: a linker in config, rustflags in config, `--release` vs
`cargo bench --no-run`, and `cargo build` vs `cargo test --no-run` (same
features). Prints, per variant, which units keep both hashes.

Usage: run.sh exp_identity.py [toolchain…]
"""

import sys
from pathlib import Path

import bbtrace as bb

HERE = Path(__file__).parent
FIX = HERE / "fixtures" / "directives"
H = bb.HOST
T = f"--target={H}"


def units(run):
    out = {}
    for r in run.records("compile"):
        a = r["args"]
        out_dir = bb.arg_value(a, "--out-dir") or ""
        plat = "target" if f"/{H}/" in out_dir else "host"
        types = ",".join(a[i + 1] for i, x in enumerate(a) if x == "--crate-type") + (",test" if "--test" in a else "")
        key = (bb.crate_name(a), types, plat)
        extra = next((a[i + 1] for i, x in enumerate(a) if x == "-C" and a[i + 1].startswith("extra-filename=")), "")
        out.setdefault(key, set()).add((bb.c_metadata(a), extra))
    return out


def compare(base, other):
    same, diff = [], []
    for k in sorted(set(base) & set(other)):
        (same if base[k] & other[k] else diff).append(k)
    return same, diff


VARIANTS = [
    ("linker", ["build", "--offline", "--workspace", T, "--config", f'target.{H}.linker="/bb/marker-linker"']),
    ("rustflags", ["build", "--offline", "--workspace", T, "--config", f'target.{H}.rustflags=["--cfg","x"]']),
    ("test-no-run", ["test", "--no-run", "--offline", "--workspace", T]),
]


def main(argv):
    tcs = argv or list(bb.toolchains())
    lines = []
    for tc in tcs:
        base = units(bb.cargo("identity-base", "trace", tc, FIX, ["build", "--offline", "--workspace", T]))
        for name, args in VARIANTS:
            other = units(bb.cargo(f"identity-{name}", "trace", tc, FIX, args))
            same, diff = compare(base, other)
            lines.append(f"{tc} build vs {name}: same {len(same)}, different {len(diff)}: {diff}")
        rel = units(bb.cargo("identity-release", "trace", tc, FIX, ["build", "--offline", "--workspace", T, "--release"]))
        bench = units(bb.cargo("identity-bench", "trace", tc, FIX, ["bench", "--no-run", "--offline", "--workspace", T]))
        same, diff = compare(rel, bench)
        lines.append(f"{tc} build --release vs bench --no-run: same {len(same)} {same}; different {len(diff)}: {diff}")
        lines.append(f"{tc} bench --no-run builds: {sorted(k for k in bench if k not in rel)} beyond build --release")
        prof = units(bb.cargo("identity-bench-profile", "trace", tc, FIX,
                              ["build", "--offline", "--workspace", T, "--profile", "bench"]))
        same, diff = compare(rel, prof)
        lines.append(f"{tc} build --release vs build --profile bench: same {len(same)}; different {len(diff)}: {diff}")
        ci = units(bb.cargo("identity-ci-profile", "trace", tc, FIX,
                            ["build", "--offline", "--workspace", T, "--profile", "ci",
                             "--config", 'profile.ci.inherits="release"']))
        same, diff = compare(rel, ci)
        lines.append(f"{tc} build --release vs custom profile ci (inherits release): same {len(same)}; different {len(diff)}: {diff}")
        noinc = units(bb.cargo("identity-noinc", "trace", tc, FIX, ["build", "--offline", "--workspace", T],
                               extra_env={"CARGO_INCREMENTAL": "0"}))
        same, diff = compare(base, noinc)
        lines.append(f"{tc} build vs CARGO_INCREMENTAL=0: same {len(same)}; different {len(diff)}: {diff}")
        test = units(bb.cargo("identity-test-no-run", "trace", tc, FIX, ["test", "--no-run", "--offline", "--workspace", T]))
        lines.append(f"{tc} test --no-run builds: " + ", ".join(f"{n}[{t}]" for n, t, p in sorted(test) if p == "target"))
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / "identity.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
