"""Spike A driver: run real Cargo and traced Cargo over a fixture, compare.

Library used by the experiment scripts in this directory. Nothing here is
breakbulk's real planner; it is the smallest code that answers the spike's
questions and doubles as a first version of the trace golden test and the
directive differential test.

Environment (set by run.sh):
  BB_SHIM        path to the breakbulk-shim binary
  BB_TOOLS_PATH  PATH entries for cc, coreutils, bash
  BB_TC_<name>   toolchain directories, e.g. BB_TC_1_95_0
"""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

HOST = "x86_64-unknown-linux-gnu"
SCRATCH = Path(os.environ.get("BB_SCRATCH", "/tmp/claude-1000/-home-schlarpc-breakbulk/spike-a/runs"))


def stage(fixture: Path, name=None) -> Path:
    """Copies a fixture to a fixed path outside $HOME.

    Cargo reads `.cargo/config.toml` from every ancestor of the working
    directory, so a fixture inside the user's home picks up
    ~/.cargo/config.toml (here: a `build.build-dir` override) even with a
    scratch CARGO_HOME.
    """
    dest = SCRATCH / "fixtures" / (name or fixture.name)
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(fixture, dest, symlinks=True)
    return dest


def toolchains():
    out = {}
    for k, v in sorted(os.environ.items()):
        if k.startswith("BB_TC_"):
            out[k[len("BB_TC_"):].replace("_", ".")] = Path(v)
    return out


def base_env(tc: Path, scratch: Path, target: Path):
    return {
        "PATH": f"{tc}/bin:{os.environ['BB_TOOLS_PATH']}",
        "HOME": str(scratch / "home"),
        "CARGO_HOME": str(scratch / "cargo-home"),
        "CARGO_TARGET_DIR": str(target),
        "RUSTC": str(tc / "bin" / "rustc"),
        "RUSTDOC": str(tc / "bin" / "rustdoc"),
        "CARGO_BUILD_JOBS": "4",
        "CARGO_TERM_COLOR": "never",
        "TERM": "dumb",
        "LC_ALL": "C",
    }


class Run:
    def __init__(self, name, mode, tc_name, fixture, cwd, args, env, scratch, target, record):
        self.name, self.mode, self.tc_name = name, mode, tc_name
        self.fixture, self.cwd, self.args, self.env = fixture, cwd, args, env
        self.scratch, self.target, self.record = scratch, target, record
        self.returncode = None
        self.stdout = self.stderr = ""

    def records(self, mode=None):
        out = []
        if not self.record or not self.record.exists():
            return out
        for p in sorted(self.record.glob("*.json")):
            if p.name == "metadata.json":
                continue
            r = json.loads(p.read_text())
            if mode is None or r["mode"] == mode:
                out.append(r)
        return out


def cargo(name, mode, tc_name, fixture, args, *, cwd=None, extra_env=None, keep=False, runner=False, stage_as=None):
    """Runs `cargo ARGS` in `fixture` (or `cwd`) with the given toolchain.

    mode: "real" (plain cargo) or "trace" (breakbulk-shim as RUSTC_WRAPPER and RUSTDOC).
    """
    tc = toolchains()[tc_name]
    scratch = SCRATCH / tc_name / name / mode
    if scratch.exists() and not keep:
        shutil.rmtree(scratch)
    scratch.mkdir(parents=True, exist_ok=True)
    (scratch / "home").mkdir(exist_ok=True)
    (scratch / "cargo-home").mkdir(exist_ok=True)
    target = scratch / "target"
    env = base_env(tc, scratch, target)
    record = None
    if mode == "trace":
        record = scratch / "record"
        record.mkdir(exist_ok=True)
        bindir = scratch / "bin"
        bindir.mkdir(exist_ok=True)
        link = bindir / "rustdoc"
        if not link.exists():
            link.symlink_to(os.environ["BB_SHIM"])
        env.update({
            "RUSTC_WRAPPER": os.environ["BB_SHIM"],
            "RUSTDOC": str(link),
            "BREAKBULK_RUSTDOC": str(tc / "bin" / "rustdoc"),
            "BREAKBULK_RECORD": str(record),
        })
    if runner:
        # A runner that records how Cargo would start a test, without running it.
        rbin = scratch / "runner.sh"
        rbin.write_text(
            "#!/bin/sh\n"
            f"d={scratch}/runs; mkdir -p \"$d\"; f=\"$d/$$.env\"\n"
            "pwd > \"$f\"; printf '%s\\n' \"$@\" >> \"$f\"; echo --- >> \"$f\"; env >> \"$f\"\n"
        )
        rbin.chmod(0o755)
        env[f"CARGO_TARGET_{HOST.upper().replace('-', '_')}_RUNNER"] = str(rbin)
    if extra_env:
        env.update(extra_env)
    fixture = stage(Path(fixture), stage_as)
    wd = fixture / cwd if cwd else fixture
    if mode == "trace":
        meta = subprocess.run(
            ["cargo", "metadata", "--format-version", "1", "--offline"],
            cwd=wd, env={k: v for k, v in env.items() if k != "RUSTC_WRAPPER"},
            capture_output=True, text=True,
        )
    run = Run(name, mode, tc_name, fixture, wd, args, env, scratch, target, record)
    if mode == "trace":
        if meta.returncode != 0:
            run.returncode, run.stderr = meta.returncode, "cargo metadata failed:\n" + meta.stderr
            return run
        (record / "metadata.json").write_text(meta.stdout)
    p = subprocess.run(["cargo", *args], cwd=wd, env=env, capture_output=True, text=True)
    run.returncode, run.stdout, run.stderr = p.returncode, p.stdout, p.stderr
    (scratch / "stdout.txt").write_text(p.stdout)
    (scratch / "stderr.txt").write_text(p.stderr)
    return run


# ---------------------------------------------------------------------------
# Parsing `cargo -v` output

RUNNING = re.compile(r"^\s+Running `(.*)`$")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)


def verbose_commands(stderr: str):
    """Commands from `Running `…`` lines: [(env dict, argv list)]."""
    out = []
    for line in stderr.splitlines():
        m = RUNNING.match(line)
        if not m:
            continue
        toks = shlex.split(m.group(1))
        env = {}
        i = 0
        while i < len(toks):
            a = ASSIGN.match(toks[i])
            if not a or "/" in a.group(1):
                break
            env[a.group(1)] = a.group(2)
            i += 1
        out.append((env, toks[i:]))
    return out


def arg_value(args, flag, prefix=""):
    for i, a in enumerate(args):
        if a == flag and i + 1 < len(args) and args[i + 1].startswith(prefix):
            return args[i + 1][len(prefix):]
        if a.startswith(flag + prefix) and flag.startswith("-") and len(flag) == 2:
            return a[len(flag + prefix):]
    return None


def c_metadata(args):
    for i, a in enumerate(args):
        if a == "-C" and i + 1 < len(args) and args[i + 1].startswith("metadata="):
            return args[i + 1][len("metadata="):]
    return None


def crate_name(args):
    return arg_value(args, "--crate-name")


# ---------------------------------------------------------------------------
# Real build-script output, parsed the way Cargo does (simplified).

def envify(s):
    return s.upper().replace("-", "_")


def parse_directives(text: str, out_dir: str):
    d = {"cfg": [], "check_cfg": [], "env": [], "paths": [], "libs": [], "link_args": [], "metadata": []}
    for line in text.splitlines():
        line = line.strip()
        old = False
        if line.startswith("cargo::"):
            data = line[len("cargo::"):]
            key, _, value = data.partition("=")
        elif line.startswith("cargo:"):
            old = True
            data = line[len("cargo:"):]
            key, _, value = data.partition("=")
            if not (key.startswith("rustc-") or key in ("rerun-if-changed", "rerun-if-env-changed", "warning", "error", "metadata")):
                key, value = "metadata", data
        else:
            continue
        if key == "rustc-cfg":
            d["cfg"].append(value)
        elif key == "rustc-check-cfg":
            d["check_cfg"].append(value)
        elif key == "rustc-env":
            k, _, v = value.partition("=")
            d["env"].append((k, v))
        elif key == "rustc-link-search":
            d["paths"].append(value)
        elif key == "rustc-link-lib":
            d["libs"].append(value)
        elif key == "rustc-flags":
            toks = value.split()
            i = 0
            while i < len(toks):
                t = toks[i]
                if t in ("-l", "-L"):
                    v = toks[i + 1]
                    i += 2
                else:
                    v = t[2:]
                    t = t[:2]
                    i += 1
                (d["libs"] if t == "-l" else d["paths"]).append(v)
        elif key.startswith("rustc-link-arg") or key == "rustc-cdylib-link-arg":
            kind = {
                "rustc-link-arg": "arg", "rustc-link-arg-bins": "arg_bins", "rustc-link-arg-tests": "arg_tests",
                "rustc-link-arg-examples": "arg_examples", "rustc-link-arg-benches": "arg_benches",
                "rustc-link-arg-cdylib": "arg_cdylib", "rustc-cdylib-link-arg": "arg_cdylib",
            }.get(key)
            if key == "rustc-link-arg-bin":
                name, _, value = value.partition("=")
                kind = f"arg_bin_{name}"
            d["link_args"].append((kind, value))
        elif key == "metadata":
            k, _, v = value.partition("=")
            d["metadata"].append((k, v))
    return d


def real_directives(run: Run):
    """{run hash: (normalized out_dir, directives)} from `<target>/**/build/<pkg>-<hash>/output`."""
    out = {}
    # Classic layout: build/<pkg>-<hash>/output; new layout (Cargo >= 1.101
    # nightly default): build/<pkg>/<hash>/run/stdout.
    files = [(f, f.parent) for f in run.target.glob("**/build/*/output")]
    files += [(f, f.parent.parent) for f in run.target.glob("**/build/*/*/run/stdout")]
    for f, unit_dir in files:
        h = unit_dir.name.rsplit("-", 1)[-1]
        out_dir = str(unit_dir / "out")
        out[h] = (norm(run, out_dir), parse_directives(norm(run, f.read_text()), out_dir))
    return out


# ---------------------------------------------------------------------------
# Normalization and sentinel expansion

def norm(run: Run, s: str):
    s = s.replace(str(run.target), "$T")
    s = s.replace(str(toolchains()[run.tc_name]), "$TC")
    s = s.replace(str(Path(run.fixture).resolve()), "$W")
    return s


SENT_ARG = re.compile(r"^__bb_([0-9a-z]+)_(cfg|lib)$")
SENT_CCFG = re.compile(r"^cfg\(__bb_([0-9a-z]+)_ccfg\)$")
SENT_SEARCH = re.compile(r"^native=(.*)/__bb_([0-9a-z]+)_search$")
SENT_SEARCH_EXT = re.compile(r"^native=/__bb_([0-9a-z]+)_search_ext$")
SENT_LINKARG = re.compile(r"^link-arg=__bb_([0-9a-z]+)_(arg(?:_bins|_tests|_examples|_benches|_cdylib|_bin_.+)?)$")
SENT_ENV = re.compile(r"^__BB_([0-9A-Z]+)_ENV$")
SENT_DEP = re.compile(r"^DEP_(.+)___BB$")
ANY_SENT = re.compile(r"__bb|__BB")


class Unexpected(Exception):
    pass


def strip_kind(p):
    m = re.match(r"^(native|crate|dependency|framework|all)=(.*)$", p)
    return m.group(2) if m else p


def expand_args(args, dirs, shapes):
    """Replaces sentinel arguments with the real directives of their run.

    Implements the wrapping table plus Cargo's value-dependent rules observed
    in the spike. `shapes` collects (kind, shape) pairs for the report.
    """
    out = []
    i = 0
    while i < len(args):
        a = args[i]
        b = args[i + 1] if i + 1 < len(args) else None
        if a == "--cfg" and b and SENT_ARG.match(b) and b.endswith("_cfg"):
            r = SENT_ARG.match(b).group(1)
            shapes.add(("rustc-cfg", "--cfg <v>"))
            COUNTS["rustc-cfg"] = COUNTS.get("rustc-cfg", 0) + 1
            for v in dirs[r][1]["cfg"]:
                out += ["--cfg", v]
            i += 2
            continue
        if a == "--check-cfg" and b and SENT_CCFG.match(b):
            r = SENT_CCFG.match(b).group(1)
            shapes.add(("rustc-check-cfg", "--check-cfg <v>"))
            COUNTS["rustc-check-cfg"] = COUNTS.get("rustc-check-cfg", 0) + 1
            for v in dirs[r][1]["check_cfg"]:
                out += ["--check-cfg", v]
            i += 2
            continue
        if a == "-l" and b and SENT_ARG.match(b) and b.endswith("_lib"):
            r = SENT_ARG.match(b).group(1)
            shapes.add(("rustc-link-lib", "-l <v>"))
            COUNTS["rustc-link-lib"] = COUNTS.get("rustc-link-lib", 0) + 1
            for v in dirs[r][1]["libs"]:
                out += ["-l", v]
            i += 2
            continue
        if a == "-L" and b and SENT_SEARCH.match(b):
            # Inside-OUT_DIR sentinel: R's values inside its own OUT_DIR, in order.
            m = SENT_SEARCH.match(b)
            r = m.group(2)
            shapes.add(("rustc-link-search", "-L <v> (values inside R's OUT_DIR)"))
            COUNTS["rustc-link-search"] = COUNTS.get("rustc-link-search", 0) + 1
            od = dirs[r][0]
            for p in dirs[r][1]["paths"]:
                if NAIVE or strip_kind(p).startswith(od):
                    out += ["-L", p]
            i += 2
            continue
        if a == "-L" and b and SENT_SEARCH_EXT.match(b):
            # Outside sentinel: R's other values, in order.
            r = SENT_SEARCH_EXT.match(b).group(1)
            shapes.add(("rustc-link-search", "-L <v> (values outside R's OUT_DIR)"))
            od = dirs[r][0]
            if not NAIVE:
                for p in dirs[r][1]["paths"]:
                    if not strip_kind(p).startswith(od):
                        out += ["-L", p]
            i += 2
            continue
        if a == "-C" and b and SENT_LINKARG.match(b):
            r = SENT_LINKARG.match(b).group(1)
            kinds = set()
            while i < len(args) and args[i] == "-C" and i + 1 < len(args) and SENT_LINKARG.match(args[i + 1]) \
                    and SENT_LINKARG.match(args[i + 1]).group(1) == r:
                kinds.add(SENT_LINKARG.match(args[i + 1]).group(2))
                i += 2
            shapes.add(("rustc-link-arg*", "-C link-arg=<v>"))
            COUNTS["rustc-link-arg*"] = COUNTS.get("rustc-link-arg*", 0) + 1
            if NAIVE:
                # Naive splice: one splice per kind, in the stub's fixed order.
                for k in sorted(kinds):
                    for kk, v in dirs[r][1]["link_args"]:
                        if kk == k:
                            out += ["-C", f"link-arg={v}"]
            else:
                for kind, v in dirs[r][1]["link_args"]:
                    if kind in kinds:
                        out += ["-C", f"link-arg={v}"]
            continue
        if ANY_SENT.search(a):
            raise Unexpected(f"sentinel in unexpected shape: {args[max(0, i - 1):i + 2]}")
        out.append(a)
        i += 1
    return out


DYLIB_VARS = ("LD_LIBRARY_PATH",)
# BB_NAIVE=1 turns off the value-dependent rules (negative control).
NAIVE = os.environ.get("BB_NAIVE") == "1"
COUNTS = {}


def expand_env(env, dirs, shapes):
    out = {}
    for k, v in env.items():
        m = SENT_ENV.match(k)
        if m:
            r = m.group(1).lower()
            shapes.add(("rustc-env", "env <K>=<V> on the compile"))
            COUNTS["rustc-env"] = COUNTS.get("rustc-env", 0) + 1
            for ek, ev in dirs[r][1]["env"]:
                out[ek] = ev
            continue
        m = SENT_DEP.match(k)
        if m:
            links = m.group(1)
            shapes.add(("metadata", f"DEP_<LINKS>_<KEY> on dependent runs"))
            COUNTS["metadata"] = COUNTS.get("metadata", 0) + 1
            for mk, mv in dirs[v][1]["metadata"]:
                out[f"DEP_{links}_{envify(mk)}"] = mv
            continue
        if k in DYLIB_VARS and "__bb_" in v:
            parts = []
            for p in v.split(":"):
                m = re.match(r"^(.*)/__bb_([0-9a-z]+)_search$", p)
                if not m:
                    parts.append(p)
                    continue
                shapes.add(("rustc-link-search", f"{k} entry (inside target dir only)"))
                root = m.group(1).split("/build/")[0]
                for sp in dirs[m.group(2)][1]["paths"]:
                    sp = strip_kind(sp)
                    if sp.startswith(root + "/"):
                        parts.append(sp)
            out[k] = ":".join(parts)
            continue
        if ANY_SENT.search(k) or ANY_SENT.search(v):
            raise Unexpected(f"sentinel in unexpected env shape: {k}={v}")
        out[k] = v
    return out


IGNORED_ENV = {"CARGO_MAKEFLAGS"}
TRACE_ONLY_ENV = {"RUSTC_WRAPPER", "BREAKBULK_RUSTDOC", "BREAKBULK_RECORD"}


def changed(env, base):
    """Keys whose value differs from what the planner gave Cargo (or are new)."""
    return {k for k, v in env.items() if base.get(k) != v}


def normalize_cmd(run, env, argv):
    return ({k: norm(run, v) for k, v in env.items()}, [norm(run, a) for a in argv])


def cargo_process_env(trace: Run):
    """Cargo's own process env, from the shim's record of `rustc -vV`."""
    for r in trace.records("query"):
        if r["args"] == ["-vV"]:
            return r["env"]
    return trace.env


def compare(real: Run, trace: Run, report):
    """Compares traced commands (with sentinels expanded) against real -v output."""
    dirs = real_directives(real)
    real_cmds = [normalize_cmd(real, e, a) for e, a in verbose_commands(real.stderr)]
    shapes = set()
    # Real compiles keyed by (crate name, -C metadata); runs keyed by OUT_DIR hash.
    real_compiles, real_runs = {}, {}
    for e, a in real_cmds:
        if a and a[0].endswith("rustc") and crate_name(a[1:]):
            real_compiles[(crate_name(a[1:]), c_metadata(a[1:]))] = (e, a[1:])
        elif a and Path(a[0]).name in ("build-script-build", "build_script_build"):
            h = Path(e.get("OUT_DIR", "")).parent.name.rsplit("-", 1)[-1]
            real_runs[h] = (e, a)
    trace_compiles, trace_runs = {}, {}
    base = cargo_process_env(trace)
    for r in trace.records("compile"):
        env = {k: norm(trace, v) for k, v in r["env"].items()}
        args = [norm(trace, a) for a in r["args"]]
        trace_compiles[(crate_name(args), c_metadata(args))] = (env, args, changed(r["env"], base))
    for r in trace.records("run"):
        env = {k: norm(trace, v) for k, v in r["env"].items()}
        trace_runs[r["tag"]] = (env, r["printed"], changed(r["env"], base))

    ok = True
    pe = cargo_process_env(trace)
    added = sorted(k for k in pe if trace.env.get(k) != pe[k])
    removed = sorted(k for k in trace.env if k not in pe)
    report.append(f"  cargo process env vs env given to cargo: added {added}, removed {removed}")
    rk, tk = set(real_compiles), set(trace_compiles)
    if rk != tk:
        ok = False
        report.append(f"  compile unit sets differ: only real {sorted(rk - tk)}; only traced {sorted(tk - rk)}")
    else:
        report.append(f"  compile units: {len(rk)}, identical (crate name, -C metadata) sets")
    if set(real_runs) != set(trace_runs):
        ok = False
        report.append(f"  build-script runs differ: real {sorted(real_runs)} traced {sorted(trace_runs)}")
    else:
        report.append(f"  build-script runs: {len(real_runs)}, identical OUT_DIR hashes")

    for key in sorted(rk & tk, key=str):
        renv, rargs = real_compiles[key]
        tenv, targs, tchanged = trace_compiles[key]
        try:
            eargs = expand_args(targs, dirs, shapes)
            eenv = expand_env(tenv, dirs, shapes)
        except Unexpected as e:
            ok = False
            report.append(f"  {key}: {e}")
            continue
        if eargs != rargs:
            ok = False
            report.append(f"  {key}: argv differs\n    real:   {rargs}\n    traced: {eargs}")
        for k, v in renv.items():
            if k in IGNORED_ENV:
                continue
            if eenv.get(k) != v:
                ok = False
                report.append(f"  {key}: env {k} real={v!r} traced={eenv.get(k)!r}")
        extra = {k for k in eenv if k in tchanged or not k.isupper() or k.startswith(("DEP_", "REAL_"))} - set(renv) - IGNORED_ENV - TRACE_ONLY_ENV
        if extra:
            ok = False
            report.append(f"  {key}: env only in trace: {sorted(extra)}")
    for h in sorted(set(real_runs) & set(trace_runs)):
        renv, _ = real_runs[h]
        tenv, _, tchanged = trace_runs[h]
        try:
            eenv = expand_env(tenv, dirs, shapes)
        except Unexpected as e:
            ok = False
            report.append(f"  run {h}: {e}")
            continue
        # Planner rewrite: Cargo hands build scripts RUSTDOC as configured,
        # which during tracing is the shim; the plan must name the real one.
        if eenv.get("RUSTDOC") == norm(trace, trace.env["RUSTDOC"]):
            eenv["RUSTDOC"] = "$TC/bin/rustdoc"
            shapes.add(("env rewrite", "RUSTDOC on build-script runs = shim, rewrite to real rustdoc"))
        for k, v in renv.items():
            if k in IGNORED_ENV:
                continue
            if eenv.get(k) != v:
                ok = False
                report.append(f"  run {h}: env {k} real={v!r} traced={eenv.get(k)!r}")
        extra = {k for k in eenv if k in tchanged or not k.isupper() or k.startswith(("DEP_", "REAL_"))} - set(renv) - IGNORED_ENV - TRACE_ONLY_ENV
        if extra:
            ok = False
            report.append(f"  run {h}: env only in trace: {sorted(extra)}")
    report.append("  sentinels expanded: " + ", ".join(f"{k}={v}" for k, v in sorted(COUNTS.items())))
    COUNTS.clear()
    report.append("  shapes seen: " + "; ".join(f"{k}: {s}" for k, s in sorted(shapes)))
    return ok


def file_listing(run: Run):
    """Files Cargo left in the target dir (excluding build-script OUT_DIRs and bookkeeping)."""
    out = set()
    for p in run.target.rglob("*"):
        rel = p.relative_to(run.target)
        parts = rel.parts
        if any(x in (".fingerprint", "fingerprint", "run", "incremental", ".rustc_info.json", "CACHEDIR.TAG", ".cargo-lock") for x in parts):
            continue
        if p.is_dir():
            continue
        if p.name in ("output", "stderr", "root-output", "invoked.timestamp", "breakbulk-stub.json", ".cargo-build-lock", ".cargo-artifact-lock"):
            continue
        out.add(str(rel))
    return out
