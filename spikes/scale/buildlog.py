#!/usr/bin/env python3
"""Read `nix build --log-format internal-json` on stdin, stamp each build
activity's start and stop, and summarize.

    nix build ... --log-format internal-json -v 2>&1 | buildlog.py OUT.json

OUT.json gets one record per derivation built: {drv, start, stop} in
seconds since the first line. Prints a summary: wall time, number built,
per-build duration percentiles, mean concurrency.
"""

import json
import statistics
import sys
import time

t0 = time.monotonic()
starts, builds = {}, []
for line in sys.stdin:
    now = time.monotonic() - t0
    if not line.startswith("@nix "):
        continue
    try:
        e = json.loads(line[5:])
    except json.JSONDecodeError:
        continue
    if e.get("action") == "start" and e.get("type") == 105:
        starts[e["id"]] = (e["fields"][0], now)
    elif e.get("action") == "stop" and e.get("id") in starts:
        drv, s = starts.pop(e["id"])
        builds.append({"drv": drv, "start": round(s, 4), "stop": round(now, 4)})
    elif e.get("action") == "msg" and e.get("level", 9) <= 0 and "error" in e.get("msg", ""):
        print(e.get("msg"), file=sys.stderr)
wall = time.monotonic() - t0
# A goal that finds no free build slot starts and stops its "building"
# activity and tries again later: keep each derivation's last attempt.
last = {}
for b in builds:
    last[b["drv"]] = b
builds = sorted(last.values(), key=lambda b: b["start"])
json.dump(builds, open(sys.argv[1], "w"), indent=0)
if not builds:
    print(json.dumps({"wall": round(wall, 2), "built": 0}))
    sys.exit(0)
d = sorted(b["stop"] - b["start"] for b in builds)
first = min(b["start"] for b in builds)
last = max(b["stop"] for b in builds)
print(json.dumps({
    "wall": round(wall, 2),
    "buildSpan": round(last - first, 2),
    "built": len(builds),
    "sumBuildSeconds": round(sum(d), 2),
    "meanConcurrency": round(sum(d) / (last - first), 2),
    "perBuild": {
        "min": round(d[0], 3),
        "median": round(statistics.median(d), 3),
        "mean": round(statistics.mean(d), 3),
        "p90": round(d[int(0.9 * len(d))], 3),
        "max": round(d[-1], 3),
    },
}))
