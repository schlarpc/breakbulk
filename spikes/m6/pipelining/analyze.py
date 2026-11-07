#!/usr/bin/env python3
"""Pipelining gap from `cargo build --timings` plus `cargo build --unit-graph`.

For each result directory (from measure.sh) this reads the per-unit timings
(cargo-timing.html's UNIT_DATA: start, duration, and the frontend section end,
which is the time rustc wrote the rmeta) and the unit graph (dependency
edges; unit indices are the same in both, since Cargo numbers units by their
sorted order in both places, see cargo src/ops/cargo_compile/mod.rs and
src/compiler/unit_graph.rs).

Edges follow Cargo's rule (cargo src/compiler/build_runner/mod.rs,
`only_requires_rmeta`): a dependent waits only for the dependency's rmeta when
both are mode=build units whose crate types are all lib/rlib. Every other edge
(build-script compile and run, proc macros, bins, tests, cdylib/staticlib)
waits for the dependency to finish.

Schedules simulated with the measured durations:

  unsplit    every unit waits for its dependencies to finish (breakbulk today;
             Cargo with build.pipelining=false)
  pipelined  Cargo's pipelining: rmeta-edges release at the rmeta time; the
             unit keeps its core until it finishes (also the CRIU backend,
             ignoring checkpoint/restore cost)
  rerun      the "rerun and stop" / -Zno-codegen split: every library with an
             rmeta-only dependent becomes two jobs, an rmeta job (frontend
             time) and an rlib job (full time), both started on the
             dependencies' rmeta; the frontend runs twice

Each schedule is list-scheduled on N cores (one unit = one core, highest
remaining critical path first) and also computed with unlimited cores
(critical path). `--overhead S` adds S seconds to every job, as a stand-in for
Nix's per-derivation cost (docs/spikes/scale.md: 0.35-0.5 s median per unit).

Usage: analyze.py [--overhead S] [--json out.json] <result-dir>...
"""
import argparse
import heapq
import json
import os
import re
import sys

LIB_TYPES = {"lib", "rlib"}


def load(resdir):
    html = open(os.path.join(resdir, "cargo-timing.html")).read()
    m = re.search(r"const UNIT_DATA = (\[.*?\]);\n", html, re.S)
    timing = {u["i"]: u for u in json.loads(m.group(1))}
    graph = json.load(open(os.path.join(resdir, "unit-graph.json")))
    meta = {}
    p = os.path.join(resdir, "meta.json")
    if os.path.exists(p):
        meta = json.load(open(p))
    units = graph["units"]
    # Sanity: the timing index must name the same package as the graph index.
    for i, t in timing.items():
        u = units[i]
        ver = u["pkg_id"].rsplit("@", 1)[-1].rsplit("#", 1)[-1]
        if ver != t["version"] or sorted(u["features"]) != sorted(t["features"]):
            sys.exit(f"{resdir}: unit {i} mismatch: {t['name']} vs {u['pkg_id']}")
    return units, timing, meta


def rlib_only(u):
    return u["mode"] == "build" and set(u["target"]["crate_types"]) <= LIB_TYPES


def build_jobs(units, timing, mode, overhead):
    """Return jobs: list of dict(dur, deps=[(job, offset_key)], marks={key: t})."""
    n = len(units)
    dur = {}
    rmeta = {}
    for i in range(n):
        t = timing.get(i)
        if t is None:  # fresh/unbuilt unit (should not happen on a clean build)
            dur[i], rmeta[i] = 0.0, 0.0
            continue
        d = t["duration"]
        r = d
        for name, sec in t.get("sections") or []:
            if name == "frontend":
                r = min(sec["end"], d)
        dur[i], rmeta[i] = d, r
    # edges: (parent, dep, pipelined?)
    edges = []
    for i, u in enumerate(units):
        for dep in u["dependencies"]:
            j = dep["index"]
            pipe = rlib_only(u) and rlib_only(units[j])
            edges.append((i, j, pipe))
        # A unit that links (or otherwise needs object code) waits for every
        # transitive dependency to finish, not only its direct ones (cargo
        # src/compiler/job_queue/mod.rs, `depend_on_deps_of_deps`).
        if not rlib_only(u):
            seen = set()
            stack = [d["index"] for d in u["dependencies"]]
            while stack:
                j = stack.pop()
                for d in units[j]["dependencies"]:
                    k = d["index"]
                    if k not in seen:
                        seen.add(k)
                        stack.append(k)
            direct = {d["index"] for d in u["dependencies"]}
            edges.extend((i, k, False) for k in seen - direct)
    needs_rmeta = {j for (i, j, p) in edges if p}

    jobs = []  # each: {"name", "dur", "marks": {"rmeta": t, "done": d}, "deps": [(jobidx, mark)]}
    unit_jobs = {}  # unit -> (job providing rmeta, job providing done)
    for i, u in enumerate(units):
        name = f"{u['pkg_id'].rsplit('/', 1)[-1]} {u['target']['name']} {u['mode']}"
        d, r = dur[i] + overhead, rmeta[i] + overhead
        if mode == "rerun" and i in needs_rmeta:
            jm = len(jobs)
            jobs.append({"name": name + " [rmeta]", "dur": r, "marks": {"rmeta": r, "done": r}, "unit": i})
            jl = len(jobs)
            jobs.append({"name": name + " [rlib]", "dur": d, "marks": {"rmeta": d, "done": d}, "unit": i})
            unit_jobs[i] = (jm, jl)
        else:
            k = len(jobs)
            marks = {"done": d, "rmeta": r if mode in ("pipelined",) else d}
            jobs.append({"name": name, "dur": d, "marks": marks, "unit": i})
            unit_jobs[i] = (k, k)
    for j in jobs:
        j["deps"] = []
    for (i, dep, pipe) in edges:
        mj, dj = unit_jobs[dep]
        if mode == "unsplit" or not pipe:
            src = (dj, "done")
        elif mode == "pipelined":
            src = (dj, "rmeta")
        else:  # rerun: rmeta comes from the rmeta job
            src = (mj, "done")
        mi, li = unit_jobs[i]
        for target in {mi, li}:
            jobs[target]["deps"].append(src)
    return jobs


def bottom_levels(jobs):
    """Longest path from a job's start to the end of the build."""
    dependents = [[] for _ in jobs]
    for k, j in enumerate(jobs):
        for (src, mark) in j["deps"]:
            dependents[src].append((k, mark))
    order = topo(jobs)
    bl = [0.0] * len(jobs)
    for k in reversed(order):
        best = jobs[k]["dur"]
        for (c, mark) in dependents[k]:
            best = max(best, jobs[k]["marks"][mark] + bl[c])
        bl[k] = best
    return bl


def topo(jobs):
    indeg = [len(j["deps"]) for j in jobs]
    dependents = [[] for _ in jobs]
    for k, j in enumerate(jobs):
        for (src, _) in j["deps"]:
            dependents[src].append(k)
    stack = [k for k, d in enumerate(indeg) if d == 0]
    out = []
    while stack:
        k = stack.pop()
        out.append(k)
        for c in dependents[k]:
            indeg[c] -= 1
            if indeg[c] == 0:
                stack.append(c)
    assert len(out) == len(jobs), "cycle"
    return out


def critical_path(jobs):
    start = [0.0] * len(jobs)
    end = 0.0
    for k in topo(jobs):
        j = jobs[k]
        s = max([start[src] + jobs[src]["marks"][mark] for (src, mark) in j["deps"]], default=0.0)
        start[k] = s
        end = max(end, s + j["dur"])
    return end


def simulate(jobs, cores, bl):
    """Event-driven list scheduling; returns makespan."""
    waiting = [len(j["deps"]) for j in jobs]
    listeners = {}
    for k, j in enumerate(jobs):
        for (src, mark) in j["deps"]:
            listeners.setdefault((src, mark), []).append(k)
    ready = []
    for k, w in enumerate(waiting):
        if w == 0:
            heapq.heappush(ready, (-bl[k], k))
    events = []  # (time, seq, kind, job, mark)
    seq = 0
    t = 0.0
    running = 0
    finished = 0
    end = 0.0
    while finished < len(jobs):
        while ready and running < cores:
            _, k = heapq.heappop(ready)
            running += 1
            for mark, off in jobs[k]["marks"].items():
                heapq.heappush(events, (t + off, seq, mark, k))
                seq += 1
        t, _, mark, k = heapq.heappop(events)
        if mark == "done":
            running -= 1
            finished += 1
            end = max(end, t)
        for c in listeners.get((k, mark), []):
            waiting[c] -= 1
            if waiting[c] == 0:
                heapq.heappush(ready, (-bl[c], c))
    return end


def analyze(resdir, overhead, cores_list):
    units, timing, meta = load(resdir)
    out = {"dir": os.path.basename(resdir.rstrip("/")), "units": len(units), "meta": meta}
    n_pipe_edges = 0
    n_edges = 0
    for u in units:
        for dep in u["dependencies"]:
            n_edges += 1
            if rlib_only(u) and rlib_only(units[dep["index"]]):
                n_pipe_edges += 1
    out["edges"] = n_edges
    out["rmeta_edges"] = n_pipe_edges
    out["cpu"] = sum(t["duration"] for t in timing.values())
    for mode in ("unsplit", "pipelined", "rerun"):
        jobs = build_jobs(units, timing, mode, overhead)
        bl = bottom_levels(jobs)
        r = {"jobs": len(jobs), "cpu": sum(j["dur"] for j in jobs), "cp": critical_path(jobs)}
        for c in cores_list:
            r[f"j{c}"] = simulate(jobs, c, bl)
        out[mode] = r
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--overhead", type=float, default=0.0)
    ap.add_argument("--cores", default="4,8,16")
    ap.add_argument("--json")
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    cores = [int(c) for c in a.cores.split(",")]
    rows = [analyze(d, a.overhead, cores) for d in a.dirs]
    cols = ["cp"] + [f"j{c}" for c in cores]
    print(f"overhead per job: {a.overhead}s")
    print(f"{'workspace':28} {'units':>5} {'cpu s':>7} {'wall@8':>6} | "
          + " | ".join(f"{c:>5}: unsplit pipe  gap%  rerun gap%" for c in cols))
    for r in rows:
        line = f"{r['dir']:28} {r['units']:5} {r['cpu']:7.1f} {r['meta'].get('wall', 0):6} | "
        parts = []
        for c in cols:
            u, p, rr = r["unsplit"][c], r["pipelined"][c], r["rerun"][c]
            parts.append(f"{'':5}  {u:7.1f} {p:5.1f} {100 * (u - p) / u:5.1f} {rr:6.1f} {100 * (u - rr) / u:4.1f}")
        print(line + " | ".join(parts))
    if a.json:
        json.dump(rows, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
