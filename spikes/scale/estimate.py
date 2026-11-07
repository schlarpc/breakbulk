#!/usr/bin/env python3
"""Estimate unit derivation sizes if library units named only their direct
dependencies (transitive rmeta files and upstream build-script flags reached
through references of the direct dependencies' outputs instead).

    estimate.py <generated dir> <results dir>

Uses the measured derivations (derivations.json) for the current shape and
a least-squares fit of .drv bytes against input derivations to price the
alternative. Linking units (bins, build scripts) keep their full input
list: they need every rlib.
"""

import json
import os
import re
import statistics
import sys

gen, res = sys.argv[1], sys.argv[2]
plan = json.load(open(f"{gen}/plan.json"))
units = plan["units"]

text = open(f"{res}/derivations.json").read()
dec, i, measured = json.JSONDecoder(), 0, {}
while i < len(text):
    if text[i].isspace():
        i += 1
        continue
    doc, i = dec.raw_decode(text, i)
    for k, v in doc.get("derivations", doc).items():
        measured[os.path.basename(k)] = v
paths = json.load(open(f"{res}/drvPaths.json"))


def direct(u):
    out = set()
    for a in u.get("args", []):
        if isinstance(a, list):
            for p in a:
                if isinstance(p, dict) and "out" in p and p.get("output") != "bin":
                    out.add(p["out"])
    return out


def link_runs(u):
    return {a["splice"] for a in u.get("args", []) if isinstance(a, dict) and a.get("kind") == "rustc-link-search"}


closure = {}


def trans(uid):
    if uid not in closure:
        s = set()
        for d in direct(units[uid]):
            s.add(d)
            s |= trans(d)
        closure[uid] = s
    return closure[uid]


pts, now, alt = [], [], []
for uid, p in paths.items():
    d = measured[os.path.basename(p)]
    n = len(d.get("inputs", {}).get("drvs", d.get("inputDrvs", {})))
    size = os.stat(p).st_size
    pts.append((n, size))
    now.append(n)
    u = units[uid]
    if u["kind"] == "compile" and u["crate"]["types"] == ["lib"]:
        own = {s["splice"] for s in u.get("envSplices", [])}
        removed = len(trans(uid) - direct(u)) + len(link_runs(u) - own)
        alt.append(n - removed)
    else:
        alt.append(n)
mx = statistics.mean(x for x, _ in pts)
my = statistics.mean(y for _, y in pts)
b = sum((x - mx) * (y - my) for x, y in pts) / sum((x - mx) ** 2 for x, _ in pts)
a = my - b * mx
print(json.dumps({
    "units": len(pts),
    "fitBytes": {"perDrv": round(a), "perInputDrv": round(b)},
    "now": {"inputDrvs": sum(now), "meanInputDrvs": round(sum(now) / len(now), 1),
            "drvBytes": sum(y for _, y in pts)},
    "directOnly": {"inputDrvs": sum(alt), "meanInputDrvs": round(sum(alt) / len(alt), 1),
                   "drvBytesEstimate": round(sum(a + b * x for x in alt))},
}))
