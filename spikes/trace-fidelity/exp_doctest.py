"""Experiment: `cargo test --doc` with RUSTDOC=shim, and `cargo test --no-run`
target selection.

Records which rustdoc invocations happen, with which arguments, whether any
test process is started (a recording runner is configured), and which
compile units Cargo asks for.

Usage: run.sh exp_doctest.py [toolchain…]
"""

import sys
from pathlib import Path

import bbtrace as bb

HERE = Path(__file__).parent
FIX = HERE / "fixtures" / "directives"
T = f"--target={bb.HOST}"


def compiles(run):
    out = []
    for r in run.records("compile"):
        a = r["args"]
        kind = "test" if "--test" in a else ",".join(a[i + 1] for i, x in enumerate(a) if x == "--crate-type")
        emit = next((x for x in a if x.startswith("--emit")), "")
        out.append(f"{bb.crate_name(a)}[{kind}] {emit}")
    return sorted(out)


def main(argv):
    tcs = argv or list(bb.toolchains())
    lines = []
    for tc in tcs:
        run = bb.cargo("doctest", "trace", tc, FIX, ["test", "--doc", "--offline", "--workspace", T], runner=True)
        lines.append(f"## {tc} cargo test --doc (exit {run.returncode})")
        if run.returncode:
            lines.append(run.stderr[-1500:])
            continue
        runs_dir = run.scratch / "runs"
        started = sorted(runs_dir.glob("*.env")) if runs_dir.exists() else []
        lines.append(f"  test processes started through the runner: {len(started)}")
        lines.append(f"  compiles: {compiles(run)}")
        lines.append(f"  build-script runs: {sorted(r['env']['CARGO_PKG_NAME'] for r in run.records('run'))}")
        lines.append(f"  rustdoc queries: {[r['args'] for r in run.records('query') if 'rustdoc' in r['program'][0]]}")
        for r in run.records("rustdoc"):
            a = [bb.norm(run, x) for x in r["args"]]
            flags = [x for x in a if x.startswith("-") and not x.startswith("-L")]
            lines.append(f"  rustdoc {bb.crate_name(a)}: cwd={bb.norm(run, r['cwd'])} flags={sorted(set(flags))}")
        lines.append("  stdout: " + " | ".join(l for l in run.stdout.splitlines() if l.strip())[:600])
        doc_lines = [l.strip() for l in run.stderr.splitlines() if "Doc-tests" in l]
        lines.append(f"  cargo printed: {doc_lines}")
        full = next((r for r in run.records("rustdoc") if bb.crate_name(r["args"]) == "c"), None)
        if full:
            lines.append("  full argv of rustdoc for c: " + " ".join(bb.norm(run, x) for x in full["args"]))
        # Target selection of `cargo test --no-run` and `cargo bench --no-run`.
        for cmd in (["test", "--no-run"], ["bench", "--no-run"]):
            r2 = bb.cargo("selection-" + cmd[0], "trace", tc, FIX, cmd + ["--offline", "--workspace", T])
            lines.append(f"## {tc} cargo {' '.join(cmd)} (exit {r2.returncode}) compiles: {compiles(r2)}")
            lines.append(f"  rustdoc records: {len(r2.records('rustdoc'))}")
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / "doctest.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
