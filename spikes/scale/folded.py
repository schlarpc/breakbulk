#!/usr/bin/env python3
"""Top frames of a collapsed-stack profile (`frame;frame;... count`)."""

import collections
import sys

self_c, incl = collections.Counter(), collections.Counter()
total = 0
for line in open(sys.argv[1]):
    stack, _, n = line.rstrip("\n").rpartition(" ")
    n = int(n)
    total += n
    # Merge per-derivation frames ("primop derivationStrict:<name>").
    frames = [f.split("primop derivationStrict:")[0] + "primop derivationStrict" if "primop derivationStrict:" in f else f
              for f in stack.split(";")]
    self_c[frames[-1]] += n
    for f in set(frames):
        incl[f] += n
top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
print(f"total samples {total}")
print("-- self")
for f, n in self_c.most_common(top):
    print(f"{100 * n / total:5.1f}%  {f[:160]}")
print("-- inclusive")
for f, n in incl.most_common(top):
    print(f"{100 * n / total:5.1f}%  {f[:160]}")
