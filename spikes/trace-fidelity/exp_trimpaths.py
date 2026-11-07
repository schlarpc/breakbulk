"""Experiment: trim-paths availability, how it shows in the trace, and its
effect on path crates outside the workspace root.

Traces multiws/ws2 (which uses `shared` and `common` from outside its root)
from two absolute locations with `profile.dev.trim-paths` set in config, and
with a manifest `[profile.dev] trim-paths` (no cargo-features).

Usage: run.sh exp_trimpaths.py [toolchain…]
"""

import json
import sys
from pathlib import Path

import bbtrace as bb

HERE = Path(__file__).parent
FIX = HERE / "fixtures" / "multiws"
T = f"--target={bb.HOST}"


def summary(run):
    out = {}
    for r in run.records("compile"):
        a = r["args"]
        remap = [x.replace(str(bb.SCRATCH), "$S") for x in a if x.startswith("--remap-path")]
        out[bb.crate_name(a)] = (bb.c_metadata(a), remap)
    runs = {r["env"]["CARGO_PKG_NAME"]: r["env"].get("CARGO_TRIM_PATHS_SCOPE") for r in run.records("run")}
    return out, runs


def main(argv):
    tcs = argv or list(bb.toolchains())
    lines = []
    for tc in tcs:
        for label, extra in (
            ("config trim-paths=object", ["--config", 'profile.dev.trim-paths="object"']),
            ("config trim-paths=all -Ztrim-paths", ["-Ztrim-paths", "--config", 'profile.dev.trim-paths="all"']),
        ):
            metas = {}
            for loc in ("multiws", "multiws-moved"):
                args = ["build", "--offline", "--workspace", T] + extra
                if extra[0].startswith("-Z"):
                    args = extra[:1] + ["build", "--offline", "--workspace", T] + extra[1:]
                run = bb.cargo(f"trim-{loc}", "trace", tc, FIX, args, cwd="ws2", stage_as=loc)
                lines.append(f"## {tc} {label} @ {loc}: exit {run.returncode}")
                warn = [l for l in run.stderr.splitlines() if "trim" in l.lower() or "error" in l.lower() or "warning" in l.lower()]
                lines += [f"    stderr: {l.strip()}" for l in warn[:6]]
                if run.returncode != 0:
                    continue
                units, runs = summary(run)
                for c, (m, remap) in sorted(units.items()):
                    lines.append(f"    {c:8} -C metadata={m} remaps={remap}")
                    metas.setdefault(c, set()).add(m)
            if metas:
                lines.append(f"  {tc} {label}: location-independent: " +
                             ", ".join(f"{c}={'yes' if len(v) == 1 else 'no'}" for c, v in sorted(metas.items())))
        # Manifest-level setting without cargo-features.
        fix2 = bb.SCRATCH / "fixtures-src" / "multiws-trim"
        if fix2.exists():
            import shutil
            shutil.rmtree(fix2)
        import shutil
        shutil.copytree(FIX, fix2)
        m = fix2 / "ws2" / "Cargo.toml"
        m.write_text(m.read_text() + '\n[profile.dev]\ntrim-paths = "object"\n')
        run = bb.cargo("trim-manifest", "trace", tc, fix2, ["build", "--offline", "--workspace", T], cwd="ws2")
        lines.append(f"## {tc} manifest [profile.dev] trim-paths without cargo-features: exit {run.returncode}")
        lines += [f"    stderr: {l.strip()}" for l in run.stderr.splitlines() if "trim" in l.lower() or "error" in l.lower()][:6]
        if run.returncode == 0:
            units, runs = summary(run)
            lines.append(f"    remaps on user2: {units['user2'][1]}; CARGO_TRIM_PATHS_SCOPE on runs: {runs}")
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / "trimpaths.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
