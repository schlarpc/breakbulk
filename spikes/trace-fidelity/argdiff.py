"""Shows the argv difference for one unit of a finished real/trace pair.

Usage: run.sh argdiff.py TOOLCHAIN RUN-NAME CRATE
"""

import difflib
import sys

import bbtrace as bb
from pathlib import Path


def main(argv):
    tc, name, crate = argv
    base = bb.SCRATCH / tc / name
    fix = bb.SCRATCH / "fixtures" / "directives"
    mk = lambda mode: bb.Run(name, mode, tc, fix, fix, [], {}, base / mode, base / mode / "target",
                             base / mode / "record" if mode == "trace" else None)
    real, trace = mk("real"), mk("trace")
    real.stderr = (base / "real" / "stderr.txt").read_text()
    trace.env = {"RUSTDOC": ""}
    dirs = bb.real_directives(real)
    for e, a in bb.verbose_commands(real.stderr):
        e, a = bb.normalize_cmd(real, e, a)
        if bb.crate_name(a[1:]) != crate:
            continue
        for r in trace.records("compile"):
            targs = [bb.norm(trace, x) for x in r["args"]]
            if bb.c_metadata(targs) != bb.c_metadata(a[1:]):
                continue
            exp = bb.expand_args(targs, dirs, set())
            for line in difflib.unified_diff(a[1:], exp, "real", "traced+expanded", lineterm="", n=2):
                print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
