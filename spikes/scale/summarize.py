#!/usr/bin/env python3
"""One table row per results directory (after measure.sh).

    summarize.py <generated dir>:<results dir> ...
"""

import json
import os
import re
import sys


def gtime(path):
    if not os.path.exists(path):
        return None, None
    t = open(path).read()
    wall = re.search(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (\S+)", t).group(1)
    parts = [float(x) for x in wall.split(":")]
    secs = sum(p * 60 ** i for i, p in enumerate(reversed(parts)))
    rss = int(re.search(r"Maximum resident set size \(kbytes\): (\d+)", t).group(1))
    return secs, rss


def cpu(res, name):
    p = f"{res}/{name}.stats"
    return json.load(open(p))["cpuTime"] if os.path.exists(p) else None


rows = []
for arg in sys.argv[1:]:
    gen, res = arg.split(":")
    st = json.load(open(f"{gen}/stats.json"))
    drv = json.load(open(f"{res}/drv-summary.json"))
    inst_wall, inst_rss = gtime(f"{res}/instantiate.time")
    fresh_wall, fresh_rss = gtime(f"{res}/eval-fresh.time")
    rep_wall, rep_rss = gtime(f"{res}/eval-repeat.time")
    base = cpu(res, "eval-baseline")
    rows.append({
        "graph": f"{st['model']} {st['crates']}",
        "units": drv["units"],
        "depth": st["maxDepth"],
        "avgClosure": st["avgClosure"],
        "planMB": round(os.stat(f"{gen}/plan.json").st_size / 1e6, 1),
        "instantiate s": round(inst_wall, 2),
        "instantiate MiB": round(inst_rss / 1024),
        "units.json MB": round(int(open(f"{res}/units.json.bytes").read()) / 1e6, 1),
        "eval cpu base": round(base, 2),
        "eval cpu parse": round(cpu(res, "eval-parse") - base, 2) if cpu(res, "eval-parse") else None,
        "eval cpu subst": round(cpu(res, "eval-subst") - cpu(res, "eval-parse"), 2) if cpu(res, "eval-subst") else None,
        "eval cpu sources": round(cpu(res, "eval-sources"), 2),
        "eval cpu repeat": round(cpu(res, "eval-repeat"), 2),
        "eval wall repeat": round(rep_wall, 1),
        "eval wall fresh": round(fresh_wall, 1),
        "eval MiB": round(max(fresh_rss, rep_rss) / 1024),
        "drv MB": round(drv["drvBytes"]["sum"] / 1e6, 1),
        "drv mean KB": round(drv["drvBytes"]["mean"] / 1e3, 1),
        "drv max KB": round(drv["drvBytes"]["max"] / 1e3),
        "inputDrvs sum": drv["inputDrvs"]["sum"],
        "inputDrvs mean": drv["inputDrvs"]["mean"],
        "inputDrvs median": drv["inputDrvs"]["median"],
        "inputDrvs max": drv["inputDrvs"]["max"],
        "passAsFile": drv["passAsFile"],
    })
keys = list(rows[0])
print("| " + " | ".join(keys) + " |")
print("|" + "---|" * len(keys))
for r in rows:
    print("| " + " | ".join(str(r[k]) for k in keys) + " |")
