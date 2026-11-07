#!/usr/bin/env python3
"""Summarize unit .drv files: sizes, input counts, BREAKBULK_UNIT lengths.

    analyze.py drvPaths.json derivations.json

drvPaths.json is `nix eval --json drvPaths`; derivations.json is
`nix derivation show` of those paths. Prints one JSON object.
"""

import json
import os
import statistics
import sys


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p / 100 * len(xs)))]


def summary(xs):
    return {
        "sum": sum(xs),
        "mean": round(statistics.mean(xs), 1),
        "median": statistics.median(xs),
        "p90": pct(xs, 90),
        "max": max(xs),
    }


def main():
    paths = json.load(open(sys.argv[1]))
    # Possibly several JSON documents (xargs splits long argument lists).
    text = open(sys.argv[2]).read()
    dec, i, byname = json.JSONDecoder(), 0, {}
    while i < len(text):
        if text[i].isspace():
            i += 1
            continue
        doc, i = dec.raw_decode(text, i)
        # `nix derivation show` keys by path (older) or by base name (newer).
        doc = doc.get("derivations", doc)
        byname.update({os.path.basename(k): v for k, v in doc.items()})
    sizes, input_drvs, input_outputs, unit_len, srcs = [], [], [], [], []
    pass_as_file = 0
    for _, p in paths.items():
        d = byname[os.path.basename(p)]
        sizes.append(os.stat(p).st_size)
        ins = d.get("inputs", {})
        drvs = ins.get("drvs", d.get("inputDrvs", {}))
        input_drvs.append(len(drvs))
        input_outputs.append(sum(len(v.get("outputs", v) if isinstance(v, dict) else v) for v in drvs.values()))
        srcs.append(len(ins.get("srcs", d.get("inputSrcs", []))))
        env = d.get("env", {})
        u = env.get("BREAKBULK_UNIT", "")
        if "BREAKBULK_UNITPath" in env or "passAsFile" in env:
            pass_as_file += 1
            u = d.get("structuredAttrs", {}).get("BREAKBULK_UNIT", "") or env.get("BREAKBULK_UNIT", "")
        unit_len.append(len(u))
    print(json.dumps({
        "units": len(paths),
        "drvBytes": summary(sizes),
        "inputDrvs": summary(input_drvs),
        "inputOutputs": summary(input_outputs),
        "inputSrcs": summary(srcs),
        "unitEnvBytes": summary(unit_len),
        "passAsFile": pass_as_file,
    }, indent=1))


if __name__ == "__main__":
    main()
