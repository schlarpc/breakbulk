"""Experiment: where do sentinels land, and in what shape?

Traces the `directives` fixture (build, and `cargo test` with a recording
runner so test processes are "started" without running anything) and prints,
for every unit, which run's sentinels it carries, of which kind and in which
shape. Output goes to results/placement-<toolchain>.txt.

Usage: run.sh exp_placement.py [toolchain…]
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

import bbtrace as bb

HERE = Path(__file__).parent
FIX = HERE / "fixtures" / "directives"
T = f"--target={bb.HOST}"

TOKEN = re.compile(r"__bb_([0-9a-f]+)_([a-z_]+(?:_bin_[A-Za-z0-9_-]+)?)|__BB_([0-9A-F]+)_ENV")


def platform(path: str):
    return "target" if f"/{bb.HOST}/" in path else "host"


def unit_label(args):
    name = bb.crate_name(args)
    types = [args[i + 1] for i, a in enumerate(args) if a == "--crate-type"]
    test = "--test" in args
    out = bb.arg_value(args, "--out-dir") or ""
    kind = "test" if test else ",".join(types)
    return f"{name} [{kind}] ({platform(out)})"


def shape_of(args, i):
    """The argv shape around a sentinel at index i, with the value abstracted."""
    a = args[i]
    prev = args[i - 1] if i > 0 else ""
    v = re.sub(r"__bb_[0-9a-f]+_", "__bb_R_", a)
    v = re.sub(r"^native=.*/(__bb_R_search)$", r"native=<OUT_DIR of R>/\1", v)
    return f"{prev} {v}" if prev.startswith("-") else v


def main(argv):
    tcs = argv or list(bb.toolchains())
    (HERE / "results").mkdir(exist_ok=True)
    for tc in tcs:
        lines = []
        for name, args, runner in [
            ("build", ["build", "--offline", "--workspace", T], False),
            ("test", ["test", "--offline", "--workspace", T], True),
        ]:
            run = bb.cargo(f"placement-{name}", "trace", tc, FIX, args, runner=runner)
            lines.append(f"## {tc}: cargo {' '.join(args)} (exit {run.returncode})")
            if run.returncode != 0:
                lines.append(run.stderr[-2000:])
                continue
            # Tag -> package of the run, and the run's platform.
            tags = {}
            for r in run.records("run"):
                tags[r["tag"]] = f"{r['env']['CARGO_PKG_NAME']}:{platform(r['env']['OUT_DIR'])}"
            lines.append("runs: " + ", ".join(f"{t}={p}" for t, p in sorted(tags.items(), key=lambda x: x[1])))
            rows = []
            for r in run.records("compile"):
                args_ = r["args"]
                found = defaultdict(list)
                for i, a in enumerate(args_):
                    for m in TOKEN.finditer(a):
                        tag = m.group(1) or m.group(3).lower()
                        found[tags.get(tag, tag)].append(shape_of(args_, i))
                for k, v in sorted(r["env"].items()):
                    for m in TOKEN.finditer(k + "=" + v):
                        tag = m.group(1) or m.group(3).lower()
                        if k.startswith("__BB_"):
                            found[tags.get(tag, tag)].append("env __BB_R_ENV")
                        else:
                            found[tags.get(tag, tag)].append(f"env {k} entry <OUT_DIR of R>/__bb_R_search")
                label = unit_label(args_)
                if found:
                    for src in sorted(found):
                        rows.append(f"  {label:45} <- {src:22} {' | '.join(found[src])}")
                else:
                    rows.append(f"  {label:45} <- (none)")
            lines += sorted(set(rows))
            for r in sorted(run.records("run"), key=lambda r: tags[r["tag"]]):
                deps = [f"{k}={tags.get(v, v)}" for k, v in sorted(r["env"].items()) if k.startswith("DEP_")]
                ld = [tags.get(m.group(1), m.group(1)) for m in TOKEN.finditer(r["env"].get("LD_LIBRARY_PATH", ""))]
                lines.append(f"  run {tags[r['tag']]:22} DEP vars: {deps or '-'}; LD_LIBRARY_PATH sentinels from: {ld or '-'}")
                lines.append(f"      printed: {r['printed']}")
            runs_dir = run.scratch / "runs"
            if runs_dir.exists():
                for f in sorted(runs_dir.glob("*.env")):
                    text = f.read_text()
                    head, _, env = text.partition("---\n")
                    hl = head.splitlines()
                    exe = Path(hl[1]).name if len(hl) > 1 else "?"
                    ld = next((l for l in env.splitlines() if l.startswith("LD_LIBRARY_PATH=")), "")
                    srcs = sorted({tags.get(m.group(1), m.group(1)) for m in TOKEN.finditer(ld)})
                    lines.append(f"  test process {exe:28} LD_LIBRARY_PATH sentinels from: {srcs}")
            rustdoc = run.records("rustdoc")
            for r in rustdoc:
                a = r["args"]
                found = sorted({tags.get(m.group(1) or m.group(3).lower(), "?") + ":" + shape_of(a, i)
                                for i, x in enumerate(a) for m in TOKEN.finditer(x)})
                envs = sorted({tags.get(m.group(1) or (m.group(3) or "").lower(), "?") + ":" + k
                               for k, v in r["env"].items() for m in TOKEN.finditer(k + "=" + v)})
                lines.append(f"  rustdoc {bb.crate_name(a)} test={r.get('test')}: args {found}; env {envs}")
        out = HERE / "results" / f"placement-{tc}.txt"
        out.write_text("\n".join(lines) + "\n")
        print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
