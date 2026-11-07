"""Experiment: does a path crate hash differently from two workspaces?

multiws/ws1 contains `shared` as a member; multiws/ws2 uses it from outside
its root; `common` lies outside both roots. Each workspace is traced from two
different absolute locations of the whole tree.

Usage: run.sh exp_multiws.py [toolchain…]
"""

import sys
from pathlib import Path

import bbtrace as bb

HERE = Path(__file__).parent
FIX = HERE / "fixtures" / "multiws"
T = f"--target={bb.HOST}"


def units(run):
    out = {}
    for r in run.records("compile"):
        a = r["args"]
        src = next((x for x in a if x.endswith(".rs")), None)
        out[bb.crate_name(a)] = (bb.c_metadata(a), src, r["env"].get("CARGO_PRIMARY_PACKAGE"),
                                 r["cwd"].replace(str(bb.SCRATCH), "$S"))
    return out


def main(argv):
    tcs = argv or list(bb.toolchains())
    lines = []
    for tc in tcs:
        res = {}
        for loc in ("multiws", "multiws-moved"):
            for ws, args in (("ws1", ["build", "--offline", "--workspace", T]),
                             ("ws1-p-user1", ["build", "--offline", "-p", "user1", T]),
                             ("ws2", ["build", "--offline", "--workspace", T])):
                run = bb.cargo(f"multiws-{loc}-{ws}", "trace", tc, FIX, args, cwd=ws.split("-")[0], stage_as=loc)
                assert run.returncode == 0, run.stderr
                res[(loc, ws)] = units(run)
        for crate in ("shared", "common"):
            lines.append(f"{tc} {crate}:")
            for k, u in sorted(res.items()):
                m, src, prim, cwd = u[crate]
                lines.append(f"    {k[0]:14} {k[1]:12} -C metadata={m} src={src.replace(str(bb.SCRATCH), '$S')} "
                             f"cwd={cwd} CARGO_PRIMARY_PACKAGE={prim}")
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / "multiws.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
