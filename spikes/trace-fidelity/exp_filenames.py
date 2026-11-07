"""Experiment: does `--print=file-names` plus the shim's emit rules name every
output rustc writes?

For each crate type and each `--emit` combination Cargo uses (and a few it
does not), compile a tiny crate with the real rustc into one directory and
run the shim in compile mode with the same arguments into another, then
compare file listings. Also checks `--test` and `-C extra-filename`.

Usage: run.sh exp_filenames.py [toolchain…]
"""

import itertools
import os
import shutil
import subprocess
import sys
from pathlib import Path

import bbtrace as bb

HERE = Path(__file__).parent

CRATE_TYPES = [["lib"], ["rlib"], ["dylib"], ["cdylib"], ["staticlib"], ["proc-macro"], ["bin"],
               ["rlib", "cdylib"], ["rlib", "cdylib", "staticlib"], ["lib", "dylib"]]
EMITS = ["dep-info,metadata,link", "dep-info,link", "dep-info,metadata", "metadata", "link", None,
         "dep-info,metadata,link,llvm-ir,asm,obj"]


def run_case(tc: Path, work: Path, types, emit, test, extra, split=None):
    src = work / "src.rs"
    body = "pub fn f() -> u32 { 1 }\n"
    if "proc-macro" in types:
        body = "extern crate proc_macro;\n#[proc_macro]\npub fn m(_: proc_macro::TokenStream) -> proc_macro::TokenStream { proc_macro::TokenStream::new() }\n"
    if "bin" in types or test:
        body += "#[allow(dead_code)] fn main() {}\n"
    src.write_text(body)
    results = {}
    for mode in ("real", "shim"):
        out = work / mode
        if out.exists():
            shutil.rmtree(out)
        out.mkdir()
        args = ["--crate-name", "foo", "--edition=2021", str(src), "--error-format=json",
                "--json=diagnostic-rendered-ansi,artifacts,future-incompat"]
        if test:
            args.append("--test")
        else:
            for t in types:
                args += ["--crate-type", t]
        if emit:
            args.append(f"--emit={emit}")
        args += ["-C", "metadata=0123456789abcdef"]
        if extra:
            args += ["-C", "extra-filename=-0123456789abcdef"]
        if split:
            args += ["-C", "debuginfo=2", "-C", f"split-debuginfo={split}"]
        args += ["--out-dir", str(out)]
        env = dict(os.environ, BREAKBULK_RECORD=str(work / "record"), PATH=f"{tc}/bin:{os.environ['BB_TOOLS_PATH']}")
        cmd = [str(tc / "bin" / "rustc"), *args] if mode == "real" else [os.environ["BB_SHIM"], str(tc / "bin" / "rustc"), *args]
        p = subprocess.run(cmd, cwd=work, env=env, capture_output=True, text=True)
        notes = sorted(l for l in p.stderr.splitlines() if '"$message_type":"artifact"' in l)
        notes = [n.replace(str(out), "OUT") for n in notes]
        results[mode] = (p.returncode, sorted(f.name for f in out.iterdir()), notes,
                         p.stderr if p.returncode else "")
    return results


def main(argv):
    tcs = argv or list(bb.toolchains())
    lines, bad = [], 0
    for tc_name in tcs:
        tc = bb.toolchains()[tc_name]
        work = bb.SCRATCH / tc_name / "filenames"
        if work.exists():
            shutil.rmtree(work)
        work.mkdir(parents=True)
        n = 0
        for types, emit, test, extra in itertools.product(CRATE_TYPES, EMITS, (False, True), (True, False)):
            if test and types != ["lib"]:
                continue
            r = run_case(tc, work, types, emit, test, extra)
            n += 1
            (rc, rf, rn, rerr), (sc, sf, sn, serr) = r["real"], r["shim"]
            label = f"{'test' if test else '+'.join(types)} emit={emit} extra={extra}"
            if rc != 0:
                lines.append(f"{tc_name} {label}: real rustc failed (skipped): {rerr.strip().splitlines()[-1] if rerr.strip() else rc}")
                continue
            if (rf, rn) != (sf, sn) or sc != 0:
                bad += 1
                lines.append(f"{tc_name} {label}: MISMATCH\n    real files {rf}\n    shim files {sf}\n"
                             f"    real notes {rn}\n    shim notes {sn}\n    shim exit {sc} {serr.strip()[:300]}")
        for types, split in itertools.product((["bin"], ["lib"], ["cdylib"]), ("packed", "unpacked")):
            r = run_case(tc, work, types, "dep-info,metadata,link", False, True, split)
            n += 1
            (rc, rf, rn, rerr), (sc, sf, sn, serr) = r["real"], r["shim"]
            if (rf, rn) != (sf, sn):
                bad += 1
                lines.append(f"{tc_name} {types} split-debuginfo={split}: MISMATCH\n    real files {rf}\n    shim files {sf}\n"
                             f"    real notes {rn}\n    shim notes {sn}")
        lines.append(f"{tc_name}: {n} cases, {bad} mismatches so far")
    (HERE / "results").mkdir(exist_ok=True)
    (HERE / "results" / "filenames.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
