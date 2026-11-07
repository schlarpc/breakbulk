"""Experiment: rustflags and linker scoping with and without `--target <host>`.

Config sets [build] rustflags, [target.<host>] rustflags and a marker linker.
Traced only (the linker does not exist). Prints, per unit, whether each flag
reached it and which `-C linker=` it got; and for build-script runs,
CARGO_ENCODED_RUSTFLAGS and RUSTC_LINKER.

Usage: run.sh exp_flags.py [toolchain…]
"""

import sys
from pathlib import Path

import bbtrace as bb

HERE = Path(__file__).parent
FIX = HERE / "fixtures" / "directives"
H = bb.HOST
CONFIG = [
    "--config", 'build.rustflags=["--cfg","bb_build_flag"]',
    "--config", f'target.{H}.rustflags=["--cfg","bb_target_flag"]',
    "--config", f'target.{H}.linker="/bb/marker-linker"',
]
VARIANTS = {
    "target-host": ["build", "--offline", "--workspace", f"--target={H}", *CONFIG],
    "no-target": ["build", "--offline", "--workspace", *CONFIG],
    # Only the linker, with --target: does the linker reach host units?
    "target-host-linker-only": ["build", "--offline", "--workspace", f"--target={H}",
                                "--config", f'target.{H}.linker="/bb/marker-linker"'],
}
NIGHTLY = {
    # Unstable: keep target config off host units entirely, with a host linker.
    "nightly-host-config": ["-Zhost-config", "-Ztarget-applies-to-host", "build", "--offline", "--workspace",
                            f"--target={H}", *CONFIG, "--config", "target-applies-to-host=false",
                            "--config", 'host.linker="/bb/host-linker"'],
}


def summarize(run):
    rows = []
    for r in run.records("compile"):
        a = r["args"]
        out = bb.arg_value(a, "--out-dir") or ""
        plat = "target" if f"/{H}/" in out else "host"
        types = ",".join(a[i + 1] for i, x in enumerate(a) if x == "--crate-type") + (",test" if "--test" in a else "")
        linker = [a[i + 1] for i, x in enumerate(a) if x == "-C" and a[i + 1].startswith("linker=")]
        flags = [f for f in ("bb_build_flag", "bb_target_flag") if f in a]
        rows.append(f"  compile {bb.crate_name(a):20} {types:16} {plat:6} flags={flags} linker={linker}")
    for r in run.records("run"):
        e = r["env"]
        plat = "target" if f"/{H}/" in e["OUT_DIR"] else "host"
        rows.append(f"  run     {e['CARGO_PKG_NAME']:20} {'':16} {plat:6} CARGO_ENCODED_RUSTFLAGS={e.get('CARGO_ENCODED_RUSTFLAGS', '')!r} "
                    f"RUSTC_LINKER={e.get('RUSTC_LINKER')!r} TARGET={e.get('TARGET')} HOST={e.get('HOST')}")
    return sorted(set(rows))


def main(argv):
    tcs = argv or list(bb.toolchains())
    lines = []
    for tc in tcs:
        variants = dict(VARIANTS)
        if tc == "nightly":
            variants.update(NIGHTLY)
        for name, args in variants.items():
            run = bb.cargo(f"flags-{name}", "trace", tc, FIX, args)
            lines.append(f"## {tc} {name}: cargo {' '.join(args)} (exit {run.returncode})")
            if run.returncode != 0:
                lines.append(run.stderr[-1500:])
                continue
            lines += summarize(run)
    (HERE / "results").mkdir(exist_ok=True)
    out = HERE / "results" / "flags.txt"
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
