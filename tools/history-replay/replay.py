#!/usr/bin/env python3
"""History replay: how much would early cutoff on rmeta bytes save?

For each commit C in a range, build C and its first parent P with a real
Cargo and rustc, hash every library's `.rmeta` and `.rlib`, and compare.
Per edit it reports:

  src      workspace packages whose files changed (plus registry packages
           added or changed in Cargo.lock)
  rmeta    libraries whose .rmeta bytes changed
  rlib     libraries whose .rlib bytes changed
  ia_lib   library compiles redone with input addressing (breakbulk today,
           and Cargo): every changed package and all its dependents
  cut_lib  library compiles redone with cutoff on rmeta bytes (full-CA
           units): a library recompiles only if its own source changed or a
           direct dependency's rmeta bytes changed
  ia_link / cut_link  link units (bins, test binaries) redone: with input
           addressing, any changed transitive dependency; with cutoff, a
           changed own source or a changed transitive rlib

Builds use one fixed source directory and one target directory per
toolchain, so absolute paths and Cargo's -C metadata stay the same across
commits; `git checkout` gives changed files a new mtime, so Cargo's freshness
check rebuilds exactly what changed. Only `--workspace --lib` is built
(link units are counted from `cargo metadata`, not built). After the range,
the last commit is rebuilt in a clean target directory and its hashes are
compared with the replayed ones: any difference means a determinism or
freshness problem and is reported as `control_mismatch`.

Usage:
  replay.py --repo DIR --work DIR --range A..B [--range-path crates ...]
            --toolchain NAME=BINDIR[,RUSTFLAGS] [--toolchain ...]
            [--profile release] [--jobs 4] [--out results.json]
Run it in a shell that has a C compiler (e.g. `nix develop`). It sets its
own CARGO_HOME under --work, so the user's Cargo config never applies.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time


def sh(args, **kw):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kw).stdout


def git(repo, *args):
    return sh(["git", "-C", repo, *args])


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Toolchain:
    def __init__(self, spec):
        name, rest = spec.split("=", 1)
        bindir, _, flags = rest.partition(",")
        self.name, self.bindir, self.rustflags = name, bindir, flags


def env_for(tc, work, target_dir):
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("CARGO_") or k in ("RUSTFLAGS", "RUSTC", "RUSTDOC", "RUSTC_WRAPPER"):
            del env[k]
    if tc.bindir:
        env["PATH"] = tc.bindir + ":" + env["PATH"]
    env["CARGO_HOME"] = os.path.join(work, "cargo-home")
    env["CARGO_TARGET_DIR"] = target_dir
    env["CARGO_INCREMENTAL"] = "0"
    if tc.rustflags:
        env["RUSTFLAGS"] = tc.rustflags
    return env


def checkout(src, rev):
    git(src, "checkout", "-q", "-f", "--detach", rev)
    git(src, "clean", "-q", "-fdx")


def metadata(src, env):
    out = sh(["cargo", "metadata", "--format-version", "1", "--locked"], cwd=src, env=env)
    return json.loads(out)


def build(src, env, profile, jobs):
    """Build workspace libs; return {lib_key: {"rmeta": hash, "rlib": hash, "fresh": bool}}."""
    p = subprocess.run(
        ["cargo", "build", "--locked", "--workspace", "--lib", "--profile", profile,
         f"-j{jobs}", "--message-format=json"],
        cwd=src, env=env, text=True, capture_output=True)
    if p.returncode != 0:
        return None, p.stderr[-4000:]
    libs = {}
    for line in p.stdout.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if m.get("reason") != "compiler-artifact":
            continue
        kinds = m["target"]["kind"]
        if not any(k in ("lib", "rlib", "proc-macro") for k in kinds):
            continue
        key = pkg_name_ver(m["package_id"]) + ":" + m["target"]["name"]
        ent = {"fresh": m["fresh"], "pm": "proc-macro" in kinds}
        for f in m["filenames"]:
            if f.endswith(".rmeta"):
                ent["rmeta"] = sha256(f)
            elif f.endswith(".rlib"):
                ent["rlib"] = sha256(f)
            elif f.endswith(".so") and ent["pm"]:
                ent["rmeta"] = ent["rlib"] = sha256(f)
        if key in libs and libs[key] != ent:
            # Same library twice (e.g. host and target feature sets): keep both.
            key += "#" + str(sum(1 for k in libs if k.startswith(key)))
        libs[key] = ent
    return libs, None


def pkg_name_ver(pkg_id):
    # Package ID specs: "registry+https://...#name@1.2.3", "path+file:///x/name#0.1.0",
    # "path+file:///x/dir#name@0.1.0". Normalise to name@version.
    tail = pkg_id.rsplit("/", 1)[-1]
    frag = tail.split("#", 1)[1] if "#" in tail else tail
    if "@" in frag:
        return frag
    return tail.split("#", 1)[0] + "@" + frag


def graph(meta):
    """Package graph from cargo metadata: per package, lib deps (normal+build)
    and dev deps, plus link-unit count and manifest dir for members."""
    pkgs = {p["id"]: p for p in meta["packages"]}
    members = set(meta["workspace_members"])
    nodes = {}
    for n in meta["resolve"]["nodes"]:
        p = pkgs[n["id"]]
        normal, dev = set(), set()
        for d in n["deps"]:
            kinds = {k["kind"] for k in d["dep_kinds"]}
            if kinds & {None, "build"}:
                normal.add(d["pkg"])
            if "dev" in kinds:
                dev.add(d["pkg"])
        link = 0
        has_lib = False
        if n["id"] in members:
            for t in p["targets"]:
                k = t["kind"]
                if "bin" in k or "test" in k:
                    link += 1
                if any(x in ("lib", "rlib", "proc-macro") for x in k):
                    has_lib = True
                    if t.get("test", True):
                        link += 1  # the library's unit-test binary
        nodes[n["id"]] = {
            "name": pkg_name_ver(n["id"]), "normal": normal, "dev": dev, "link": link,
            "member": n["id"] in members, "dir": os.path.dirname(p["manifest_path"]),
            "has_lib": has_lib or n["id"] not in members,
        }
    return nodes


def changed_packages(files, root, gprev, gcur):
    members = sorted(((v["dir"], k) for k, v in gcur.items() if v["member"]),
                     key=lambda x: -len(x[0]))
    changed, other = set(), []
    for f in files:
        absf = os.path.join(root, f)
        for d, k in members:
            if absf.startswith(d + "/"):
                changed.add(k)
                break
        else:
            other.append(f)
    # Registry/git packages that are new in this commit's resolve.
    for k, v in gcur.items():
        if not v["member"] and k not in gprev:
            changed.add(k)
    return changed, files, other


def closure_dependents(g, seeds, include_dev=False):
    rev = {}
    for k, v in g.items():
        for d in v["normal"] | (v["dev"] if include_dev else set()):
            rev.setdefault(d, set()).add(k)
    out, stack = set(seeds), list(seeds)
    while stack:
        x = stack.pop()
        for y in rev.get(x, ()):
            if y not in out:
                out.add(y)
                stack.append(y)
    return out


def transitive_deps(g, k, with_dev):
    seen, stack = set(), list(g[k]["normal"] | (g[k]["dev"] if with_dev else set()))
    while stack:
        x = stack.pop()
        if x in seen or x not in g:
            continue
        seen.add(x)
        stack.extend(g[x]["normal"])
    return seen


def lib_hash(libs, g, k, field):
    name = g[k]["name"]
    vals = sorted(v.get(field, "") for key, v in libs.items() if key.split(":")[0] == name)
    return tuple(vals)


def compare(gp, gc, lp, lc, changed):
    # Libraries actually built at this commit (metadata also lists
    # platform-specific packages that are never compiled here).
    libs_c = [k for k, v in gc.items() if v["has_lib"] and lib_hash(lc, gc, k, "rmeta")]
    def differs(k, field):
        return k not in gp or lib_hash(lp, gp, k, field) != lib_hash(lc, gc, k, field)
    rmeta_changed = {k for k in libs_c if differs(k, "rmeta")}
    rlib_changed = {k for k in libs_c if differs(k, "rlib")}
    src_libs = {k for k in changed if k in gc and gc[k]["has_lib"]}
    # Libraries whose own inputs changed although no file of theirs did
    # (features, flags, a new version in Cargo.lock): their rmeta changed
    # and no direct dependency's did. Input addressing rebuilds them too.
    self_changed = {k for k in rmeta_changed if not (gc[k]["normal"] & rmeta_changed)}
    ia_lib = closure_dependents(gc, src_libs | self_changed) & set(libs_c)
    cut_lib = {k for k in libs_c if k in src_libs or (gc[k]["normal"] & rmeta_changed)}
    ia_link = cut_link = 0
    for k, v in gc.items():
        if not v["member"] or not v["link"]:
            continue
        deps = transitive_deps(gc, k, True)
        if k in changed or deps & (ia_lib | rlib_changed):
            ia_link += v["link"]
        if k in changed or deps & rlib_changed:
            cut_link += v["link"]
    return {
        "src": sorted(gc[k]["name"] for k in changed if k in gc),
        "rmeta": sorted(gc[k]["name"] for k in rmeta_changed),
        "rlib": sorted(gc[k]["name"] for k in rlib_changed),
        "src_rmeta_same": sorted(gc[k]["name"] for k in src_libs - rmeta_changed),
        "n_src": len(changed), "n_src_libs": len(src_libs), "n_rmeta": len(rmeta_changed),
        "n_rlib": len(rlib_changed),
        "ia_lib": len(ia_lib), "cut_lib": len(cut_lib),
        "ia_link": ia_link, "cut_link": cut_link,
        "libs_total": len(libs_c),
        "link_total": sum(v["link"] for v in gc.values() if v["member"]),
    }


def make_rows(snaps, pairinfo, root):
    rows = []
    for c, info in pairinfo.items():
        p = info["parent"]
        sp, sc = snaps.get(p, {}), snaps.get(c, {})
        if "libs" not in sp or "libs" not in sc:
            rows.append({"commit": c, "subject": info["subject"], "skipped": "build failed",
                         "error": (sp.get("error") or sc.get("error") or "")[-500:]})
            continue
        changed, files, other = changed_packages(info["files"], root, sp["graph"], sc["graph"])
        row = {"commit": c, "subject": info["subject"], "files": len(files), "outside_members": other}
        row.update(compare(sp["graph"], sc["graph"], sp["libs"], sc["libs"], changed))
        rows.append(row)
    return rows


def dump_snaps(snaps):
    """Snapshots as JSON (sets as sorted lists), for --reanalyze."""
    out = {}
    for rev, s in snaps.items():
        if "graph" in s:
            g = {k: dict(v, normal=sorted(v["normal"]), dev=sorted(v["dev"])) for k, v in s["graph"].items()}
            out[rev] = {"libs": s["libs"], "graph": g}
        else:
            out[rev] = s
    return out


def load_snaps(js):
    out = {}
    for rev, s in js.items():
        if "graph" in s:
            g = {k: dict(v, normal=set(v["normal"]), dev=set(v["dev"])) for k, v in s["graph"].items()}
            out[rev] = {"libs": s["libs"], "graph": g}
        else:
            out[rev] = s
    return out


def reanalyze(path):
    """Recompute every row from the snapshots saved in a results file."""
    results = json.load(open(path))
    for t in results["toolchains"].values():
        t["rows"] = make_rows(load_snaps(t["snapshots"]), t["pairs"], t["root"])
    json.dump(results, open(path, "w"), indent=1)
    summarize(results)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--range", required=True, help="git rev-list range, e.g. HEAD~50..HEAD")
    ap.add_argument("--range-path", nargs="*", default=[], help="only commits touching these paths")
    ap.add_argument("--first-parent", action="store_true")
    ap.add_argument("--toolchain", action="append", required=True)
    ap.add_argument("--profile", default="release")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", required=True)
    ap.add_argument("--no-control", action="store_true")
    a = ap.parse_args()

    work = os.path.abspath(a.work)
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, "src")
    if not os.path.isdir(src):
        sh(["git", "clone", "-q", "--no-checkout", os.path.abspath(a.repo), src])
    revlist = ["rev-list", "--reverse", "--no-merges"]
    if a.first_parent:
        revlist.append("--first-parent")
    commits = git(a.repo, *revlist, a.range, "--", *a.range_path).split()
    sh(["git", "-C", src, "fetch", "-q", os.path.abspath(a.repo), "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*"])
    pairs = [(git(a.repo, "rev-parse", c + "^").strip(), c) for c in commits]
    order = []
    for p, c in pairs:
        for x in (p, c):
            if x not in order:
                order.append(x)
    results = {"repo": a.repo, "range": a.range, "range_path": a.range_path,
               "profile": a.profile, "commits": commits, "toolchains": {}}
    for spec in a.toolchain:
        tc = Toolchain(spec)
        tdir = os.path.join(work, "target-" + tc.name)
        env = env_for(tc, work, tdir)
        snaps = {}
        version = sh(["rustc", "-V"], env=env).strip()
        t0 = time.time()
        for i, rev in enumerate(order):
            checkout(src, rev)
            try:
                meta = metadata(src, env)
            except subprocess.CalledProcessError as e:
                snaps[rev] = {"error": "metadata: " + e.stderr[-2000:]}
                continue
            libs, err = build(src, env, a.profile, a.jobs)
            snaps[rev] = {"libs": libs, "graph": graph(meta)} if libs is not None else {"error": err}
            print(f"[{tc.name}] {i + 1}/{len(order)} {rev[:10]} "
                  f"{'ERR' if libs is None else 'ok'} {time.time() - t0:.0f}s", file=sys.stderr)
        pairinfo = {}
        for p, c in pairs:
            pairinfo[c] = {
                "parent": p,
                "subject": git(a.repo, "log", "-1", "--format=%s", c).strip(),
                "files": git(src, "diff", "--name-only", p, c).split(),
            }
        root = git(src, "rev-parse", "--show-toplevel").strip()
        rows = make_rows(snaps, pairinfo, root)
        control = None
        if not a.no_control and order:
            # Clean rebuild of the last commit at the same target path (the
            # path reaches outputs through OUT_DIR includes).
            last = order[-1]
            aside = tdir + ".replay"
            shutil.rmtree(aside, ignore_errors=True)
            os.rename(tdir, aside)
            checkout(src, last)
            libs, err = build(src, env, a.profile, a.jobs)
            if libs is not None and "libs" in snaps[last]:
                rep = snaps[last]["libs"]
                control = sorted(k for k in libs
                                 if {f: libs[k].get(f) for f in ("rmeta", "rlib")}
                                 != {f: rep.get(k, {}).get(f) for f in ("rmeta", "rlib")})
            shutil.rmtree(tdir, ignore_errors=True)
            os.rename(aside, tdir)
        results["toolchains"][tc.name] = {"rustc": version, "rustflags": tc.rustflags,
                                          "rows": rows, "control_mismatch": control,
                                          "pairs": pairinfo, "root": root,
                                          "snapshots": dump_snaps(snaps)}
        json.dump(results, open(a.out, "w"), indent=1)
    summarize(results)


def summarize(results):
    for name, t in results["toolchains"].items():
        rows = [r for r in t["rows"] if "skipped" not in r]
        edits = [r for r in rows if r["n_src_libs"] > 0]
        print(f"\n== {name}: {t['rustc']} {t['rustflags']}")
        print(f"commits {len(t['rows'])}, built {len(rows)}, touching a library {len(edits)}; "
              f"control mismatch: {t['control_mismatch']}")
        if not rows:
            continue
        s = lambda k: sum(r[k] for r in rows)
        self_cut = sum(len(r["src_rmeta_same"]) for r in edits)
        print(f"edited libraries: {s('n_src_libs')}, of which rmeta unchanged: {self_cut}")
        print(f"library compiles: input-addressed {s('ia_lib')}, rmeta cutoff {s('cut_lib')}"
              f" ({100 * (1 - s('cut_lib') / max(1, s('ia_lib'))):.0f}% fewer)")
        print(f"link units:       input-addressed {s('ia_link')}, rlib cutoff {s('cut_link')}"
              f" ({100 * (1 - s('cut_link') / max(1, s('ia_link'))):.0f}% fewer)")
        print(f"{'commit':10} {'src':>3} {'rmeta':>5} {'rlib':>4} {'ia':>3} {'cut':>3} {'iaL':>4} {'cutL':>4}  subject")
        for r in t["rows"]:
            if "skipped" in r:
                print(f"{r['commit'][:10]} skipped: {r['skipped']}")
                continue
            print(f"{r['commit'][:10]} {r['n_src']:3} {r['n_rmeta']:5} {r['n_rlib']:4} {r['ia_lib']:3} "
                  f"{r['cut_lib']:3} {r['ia_link']:4} {r['cut_link']:4}  {r['subject'][:60]}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--summarize":
        summarize(json.load(open(sys.argv[2])))
    elif len(sys.argv) == 3 and sys.argv[1] == "--reanalyze":
        reanalyze(sys.argv[2])
    else:
        main()
