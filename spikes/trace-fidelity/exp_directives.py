"""Experiment: real vs traced Cargo on the `directives` fixture.

For each toolchain and command: run real `cargo … -v`, run the same command
traced, then
  * check Cargo accepted the faked outputs (exit 0),
  * compare (crate, -C metadata) sets and build-script run hashes,
  * expand sentinels with the real build scripts' output and diff argv/env,
  * diff the target-dir file listings (faked output names vs real).

Usage: run.sh exp_directives.py [toolchain…] [--cmd NAME…]
"""

import sys
from pathlib import Path

import bbtrace as bb

FIX = Path(__file__).parent / "fixtures" / "directives"
T = f"--target={bb.HOST}"
COMMANDS = {
    "build": ["build", "-vv", "--offline", "--workspace", T],
    "build-release": ["build", "-vv", "--offline", "--workspace", T, "--release"],
    "check": ["check", "-vv", "--offline", "--workspace", T],
    "test-no-run": ["test", "--no-run", "-vv", "--offline", "--workspace", T],
    "build-no-target": ["build", "-vv", "--offline", "--workspace"],
    # `links` overrides: Cargo skips a-sys's and hostdep's build scripts and
    # passes these values itself (including DEP_A_KEY to b-sys's script).
    "links-override": [
        "build", "-vv", "--offline", "--workspace", T,
        "--config", f'target.{bb.HOST}.a.rustc-link-lib=["m"]',
        "--config", f'target.{bb.HOST}.a.rustc-link-search=["native=/tmp/bb-override-a"]',
        "--config", f'target.{bb.HOST}.a.rustc-cfg=["over_a"]',
        "--config", f'target.{bb.HOST}.a.rustc-env.REAL_A_SYS_ENV="over"',
        "--config", f'target.{bb.HOST}.a.key="over_val"',
        "--config", f'target.{bb.HOST}.hostdep.rustc-cfg=["over_hostdep"]',
    ],
}


def main(argv):
    tcs = [a for a in argv if not a.startswith("--")] or list(bb.toolchains())
    cmds = list(COMMANDS)
    if "--cmd" in argv:
        cmds = argv[argv.index("--cmd") + 1:]
        tcs = [a for a in argv[:argv.index("--cmd")]] or list(bb.toolchains())
    all_ok = True
    for tc in tcs:
        for name in cmds:
            args = COMMANDS[name]
            real = bb.cargo(f"directives-{name}", "real", tc, FIX, args)
            trace = bb.cargo(f"directives-{name}", "trace", tc, FIX, args)
            print(f"== {tc} {name}: real exit {real.returncode}, trace exit {trace.returncode}")
            if real.returncode != 0:
                print(real.stderr[-3000:])
            if trace.returncode != 0:
                print(trace.stderr[-3000:])
            report = []
            ok = real.returncode == 0 and trace.returncode == 0 and bb.compare(real, trace, report)
            rl, tl = bb.file_listing(real), bb.file_listing(trace)
            only_real, only_trace = sorted(rl - tl), sorted(tl - rl)
            if only_real or only_trace:
                report.append(f"  target listing: only real {only_real}; only traced {only_trace}")
            else:
                report.append(f"  target listing: {len(rl)} files, identical names")
            print("\n".join(report))
            print("  RESULT:", "OK" if ok else "DIFF")
            all_ok &= ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
