"""Per-check build times from a timestamped `--log-format internal-json` log.

  profile.py record LOG -- nix build ... --log-format internal-json -v
      runs the command, writing its stderr to LOG with a time on each line
  profile.py report LOG CHECKS.json
      CHECKS.json: {"<check>": "<drv path>"}; prints a Markdown report

Nix's internal-json events carry no time, so `record` stamps each line as
it arrives. A build is a `start` event of type 105 (actBuild, its .drv in
`fields[0]`) and the `stop` event with the same id; a substitution is type
108 (actSubstitute, its path in `fields[0]`).

Each check is charged for every build in its .drv closure, so a build
several checks share counts in each ("total"); "exclusive" counts only
builds no other check needs, which is what dropping the check saves.
"""

import json
import subprocess
import sys
import time


def record(log, cmd):
    start = time.time()
    with open(log, "w") as out:
        proc = subprocess.Popen(cmd, stderr=subprocess.PIPE, text=True, errors="replace")
        for line in proc.stderr:
            out.write(f"{time.time() - start:.3f} {line}")
        out.write(f"{time.time() - start:.3f} @exit {proc.wait()}\n")
    return proc.returncode


def spans(log):
    """{drv or path: (kind, seconds)} and the log's total seconds."""
    open_, done, end = {}, {}, 0.0
    for line in open(log, errors="replace"):
        t, _, rest = line.partition(" ")
        end = float(t)
        if not rest.startswith("@nix "):
            continue
        e = json.loads(rest[5:])
        if e.get("action") == "start" and e.get("type") in (105, 108):
            kind = "build" if e["type"] == 105 else "substitute"
            open_[e["id"]] = (e["fields"][0], kind, float(t))
        elif e.get("action") == "stop" and e.get("id") in open_:
            what, kind, t0 = open_.pop(e["id"])
            done[what] = (kind, float(t) - t0)
    return done, end


def closure(drv):
    out = subprocess.run(["nix-store", "-qR", drv], check=True, capture_output=True, text=True).stdout
    return set(out.split())


def report(log, checks_json):
    done, end = spans(log)
    checks = json.load(open(checks_json))
    builds = {d: s for d, (k, s) in done.items() if k == "build"}
    subst = sum(s for k, s in done.values() if k == "substitute")
    owned = {c: closure(d) & builds.keys() for c, d in checks.items()}
    users = {}
    for c, ds in owned.items():
        for d in ds:
            users.setdefault(d, []).append(c)
    rows = []
    for c, ds in owned.items():
        total = sum(builds[d] for d in ds)
        excl = sum(builds[d] for d in ds if len(users[d]) == 1)
        top = max(ds, key=builds.get, default=None)
        rows.append((total, excl, len(ds), c, top))
    rows.sort(reverse=True)
    print(f"Wall time {end / 60:.1f} min; {len(builds)} builds, {sum(builds.values()) / 60:.1f} build-min;"
          f" substitutions {subst / 60:.1f} min.\n")
    print("| Check | Total (min) | Exclusive (min) | Builds | Longest build |")
    print("|---|---|---|---|---|")
    for total, excl, n, c, top in rows:
        name = top.rsplit("/", 1)[-1].split("-", 1)[1] if top else ""
        lt = f"{name} ({builds[top] / 60:.1f})" if top else ""
        print(f"| `{c}` | {total / 60:.1f} | {excl / 60:.1f} | {n} | {lt} |")
    lost = sum(s for d, s in builds.items() if d not in users)
    print(f"\nBuilds in no check's closure (import-from-derivation during evaluation, mostly):"
          f" {lost / 60:.1f} build-min.")
    print("\nLongest builds:\n")
    for d, s in sorted(builds.items(), key=lambda kv: -kv[1])[:25]:
        print(f"- {s / 60:.1f} min `{d.rsplit('/', 1)[-1]}` ({len(users.get(d, []))} checks)")


if __name__ == "__main__":
    if sys.argv[1] == "record":
        sys.exit(record(sys.argv[2], sys.argv[sys.argv.index("--") + 1:]))
    report(sys.argv[2], sys.argv[3])
