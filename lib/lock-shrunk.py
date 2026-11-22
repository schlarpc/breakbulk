# lock-shrunk.py TRIMMED RESULT: fail unless the Cargo.lock RESULT only
# lost packages and dependency edges relative to TRIMMED (lib/tools.nix).
# Packages are (name, version, source) with their checksum; edges are
# resolved to packages, since Cargo shortens `name version` to `name` once
# only one version is left.
import sys
import tomllib


def load(path):
    with open(path, "rb") as f:
        lock = tomllib.load(f)
    pkgs = lock.get("package", [])
    by_name = {}
    for p in pkgs:
        by_name.setdefault(p["name"], []).append(p)

    def key(p):
        return (p["name"], p["version"], p.get("source"))

    def resolve(owner, dep):
        name, _, rest = dep.partition(" ")
        version, _, source = rest.partition(" ")
        source = source[1:-1] if source else None
        found = [
            p
            for p in by_name.get(name, [])
            if (not version or p["version"] == version)
            and (source is None or p.get("source") == source)
        ]
        if len(found) != 1:
            sys.exit(f"{path}: {owner}'s dependency `{dep}` matches {len(found)} packages")
        return key(found[0])

    return {
        key(p): (
            p.get("checksum"),
            {resolve(p["name"], d) for d in p.get("dependencies", [])},
        )
        for p in pkgs
    }


def show(k):
    name, version, source = k
    return f"{name} {version}" + (f" ({source})" if source else "")


trimmed, result = load(sys.argv[1]), load(sys.argv[2])
problems = []
for k, (checksum, edges) in result.items():
    if k not in trimmed:
        problems.append(f"Cargo added {show(k)}")
        continue
    if checksum != trimmed[k][0]:
        problems.append(f"Cargo changed the checksum of {show(k)}")
    for e in sorted(edges - trimmed[k][1]):
        problems.append(f"Cargo added the edge {show(k)} -> {show(e)}")
if problems:
    sys.exit(
        "the trimmed Cargo.lock (lib/tools.nix) is missing what Cargo resolved:\n  "
        + "\n  ".join(problems)
    )
