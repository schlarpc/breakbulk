#!/usr/bin/env python3
"""Copy measure.sh result directories into a compact form for the repo:
meta.json, unit-data.json (cargo-timing.html's UNIT_DATA) and a trimmed
unit-graph.json (no profiles or source paths). analyze.py reads either form.

Usage: save.py <dest-dir> <result-dir>...
"""
import json
import os
import re
import shutil
import sys

dest = sys.argv[1]
for src in sys.argv[2:]:
    out = os.path.join(dest, os.path.basename(src.rstrip("/")))
    os.makedirs(out, exist_ok=True)
    shutil.copy(os.path.join(src, "meta.json"), out)
    html = open(os.path.join(src, "cargo-timing.html")).read()
    data = re.search(r"const UNIT_DATA = (\[.*?\]);\n", html, re.S).group(1)
    json.dump(json.loads(data), open(os.path.join(out, "unit-data.json"), "w"))
    g = json.load(open(os.path.join(src, "unit-graph.json")))
    units = [
        {
            "pkg_id": re.sub(r"path\+file://[^#]*/", "path+file:///ws/", u["pkg_id"]),
            "target": {k: u["target"][k] for k in ("name", "kind", "crate_types")},
            "mode": u["mode"],
            "features": u["features"],
            "dependencies": [{"index": d["index"]} for d in u["dependencies"]],
        }
        for u in g["units"]
    ]
    json.dump({"version": g["version"], "units": units, "roots": g["roots"]},
              open(os.path.join(out, "unit-graph.json"), "w"))
