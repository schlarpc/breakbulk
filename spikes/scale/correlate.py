#!/usr/bin/env python3
"""Per-unit build time against the unit's input count.

    correlate.py <results dir> [build tag]

Matches the timed builds (build-<tag>.json) to derivations.json by
derivation name (the salt changes paths, not names), buckets units by
their number of input derivations, and fits time = a + b * inputs.
"""

import json
import os
import re
import statistics
import sys

res = sys.argv[1]
tag = sys.argv[2] if len(sys.argv) > 2 else "8x1"
text = open(f"{res}/derivations.json").read()
dec, i, inputs = json.JSONDecoder(), 0, {}
while i < len(text):
    if text[i].isspace():
        i += 1
        continue
    doc, i = dec.raw_decode(text, i)
    for k, v in doc.get("derivations", doc).items():
        name = re.sub(r"^[a-z0-9]{32}-", "", os.path.basename(k))
        inputs[name] = len(v.get("inputs", {}).get("drvs", v.get("inputDrvs", {})))
builds = json.load(open(f"{res}/build-{tag}.json"))
pts = []
for b in builds:
    name = re.sub(r"^[a-z0-9]{32}-", "", os.path.basename(b["drv"]))
    if name in inputs:
        kind = name.rsplit("-", 1)[-1].removesuffix(".drv")
        pts.append((inputs[name], b["stop"] - b["start"], name))
xs = [p[0] for p in pts]
ys = [p[1] for p in pts]
mx, my = statistics.mean(xs), statistics.mean(ys)
b = sum((x - mx) * (y - my) for x, y in pts and zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
a = my - b * mx
print(f"units {len(pts)}  fit: seconds = {a:.3f} + {b * 1000:.3f} ms * inputDrvs")
buckets = [(0, 5), (5, 10), (10, 25), (25, 100), (100, 400), (400, 10**9)]
for lo, hi in buckets:
    sel = [y for x, y in zip(xs, ys) if lo <= x < hi]
    if sel:
        print(f"inputs [{lo},{hi}): n={len(sel):5}  median {statistics.median(sel):.3f}s  mean {statistics.mean(sel):.3f}s")
for kind in ("lib", "build-script", "build-run", "bin"):
    sel = [y for x, y, n in pts if n.endswith(f"-{kind}.drv")]
    if sel:
        print(f"{kind:13} n={len(sel):5}  median {statistics.median(sel):.3f}s  mean {statistics.mean(sel):.3f}s")
