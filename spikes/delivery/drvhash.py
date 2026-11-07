"""Stand-in for the Rust instantiator's derivation hashing (harmonia's
`hash_modulo` / `fill_deferred_outputs` / `print_derivation_aterm`).

usage: drvhash.py <drv.json> <aterm-out> <drv-cache-dir>

<drv.json> is a derivation in Nix's JSON format version 4 with deferred
(empty) input-addressed outputs. Input .drv files are read from
<drv-cache-dir>/<basename> if present (derivations this build added, which
builder-rpc-v0 does not make visible in the sandbox), otherwise from the store.
Writes the ATerm with output paths filled in, and prints {output: path}.

Mirrors Nix's src/libstore/derivations.cc: unparse(), hashDerivationModulo()
and Store::makeOutputPath(); store-path hashing from
src/libstore/store-dir-config.cc (makeStorePath, compressHash, base32).
"""
import hashlib
import json
import os
import sys

STORE = os.environ.get("NIX_STORE", "/nix/store")
B32 = "0123456789abcdfghijklmnpqrsvwxyz"


def nix_base32(b: bytes) -> str:
    n = (len(b) * 8 - 1) // 5 + 1
    out = []
    for i in range(n - 1, -1, -1):
        bit = i * 5
        j, k = divmod(bit, 8)
        c = (b[j] >> k) | ((b[j + 1] << (8 - k)) if j + 1 < len(b) else 0)
        out.append(B32[c & 0x1F])
    return "".join(out)


def compress(h: bytes, size: int) -> bytes:
    r = bytearray(size)
    for i, x in enumerate(h):
        r[i % size] ^= x
    return bytes(r)


def make_store_path(typ: str, hexhash: str, name: str) -> str:
    s = f"{typ}:sha256:{hexhash}:{STORE}:{name}"
    return f"{STORE}/{nix_base32(compress(hashlib.sha256(s.encode()).digest(), 20))}-{name}"


def esc(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t") + '"'


def unparse(d) -> str:
    """d: {outputs: {name: (path, algo, hash)}, inputDrvs: {key: [outs]},
    srcs: [paths], system, builder, args, env}"""
    outs = ",".join(f"({esc(k)},{esc(p)},{esc(a)},{esc(h)})" for k, (p, a, h) in sorted(d["outputs"].items()))
    drvs = ",".join(f"({esc(k)},[{','.join(esc(o) for o in sorted(v))}])" for k, v in sorted(d["inputDrvs"].items()))
    srcs = ",".join(esc(s) for s in sorted(d["srcs"]))
    args = ",".join(esc(a) for a in d["args"])
    env = ",".join(f"({esc(k)},{esc(v)})" for k, v in sorted(d["env"].items()))
    return f"Derive([{outs}],[{drvs}],[{srcs}],{esc(d['system'])},{esc(d['builder'])},[{args}],[{env}])"


# --- minimal ATerm parser (for input .drv files) ---
def parse_aterm(s: str):
    pos = 0

    def expect(t):
        nonlocal pos
        assert s.startswith(t, pos), (t, s[pos:pos + 40])
        pos += len(t)

    def string():
        nonlocal pos
        expect('"')
        out = []
        while s[pos] != '"':
            c = s[pos]
            if c == "\\":
                pos += 1
                c = {"n": "\n", "r": "\r", "t": "\t"}.get(s[pos], s[pos])
            out.append(c)
            pos += 1
        pos += 1
        return "".join(out)

    def lst(item):
        nonlocal pos
        expect("[")
        out = []
        while s[pos] != "]":
            out.append(item())
            if s[pos] == ",":
                pos += 1
        pos += 1
        return out

    def tup(n):
        def f():
            nonlocal pos
            expect("(")
            vals = []
            for i in range(n):
                vals.append(string() if s[pos] == '"' else lst(string))
                if i < n - 1:
                    expect(",")
            expect(")")
            return vals
        return f

    expect("Derive(")
    outs = lst(tup(4)); expect(",")
    drvs = lst(tup(2)); expect(",")
    srcs = lst(string); expect(",")
    system = string(); expect(",")
    builder = string(); expect(",")
    args = lst(string); expect(",")
    env = lst(tup(2)); expect(")")
    return {
        "outputs": {o[0]: (o[1], o[2], o[3]) for o in outs},
        "inputDrvs": {d[0]: d[1] for d in drvs},
        "srcs": srcs, "system": system, "builder": builder, "args": args,
        "env": {k: v for k, v in env},
    }


CACHE = {}


def read_drv(path, cache_dir):
    local = os.path.join(cache_dir, os.path.basename(path))
    with open(local if os.path.exists(local) else path) as f:
        return parse_aterm(f.read())


def hash_modulo(d, mask, cache_dir) -> str:
    """hashDerivationModulo for input-addressed and fixed-output derivations."""
    if len(d["outputs"]) == 1 and "out" in d["outputs"] and d["outputs"]["out"][2]:
        p, algo, h = d["outputs"]["out"]
        return hashlib.sha256(f"fixed:out:{algo}:{h}:{p}".encode()).hexdigest()
    inputs = {}
    for drv_path, outs in d["inputDrvs"].items():
        if drv_path not in CACHE:
            CACHE[drv_path] = hash_modulo(read_drv(drv_path, cache_dir), False, cache_dir)
        inputs[CACHE[drv_path]] = outs
    m = dict(d, inputDrvs=inputs)
    if mask:
        m["outputs"] = {k: ("", a, h) for k, (_, a, h) in d["outputs"].items()}
        m["env"] = dict(d["env"], **{k: "" for k in d["outputs"]})
    return hashlib.sha256(unparse(m).encode()).hexdigest()


def main():
    src, aterm_out, cache_dir = sys.argv[1:4]
    j = json.load(open(src))
    sp = lambda b: f"{STORE}/{b}"
    d = {
        "outputs": {o: ("", "", "") for o in j["outputs"]},
        "inputDrvs": {sp(k): v["outputs"] for k, v in j["inputs"]["drvs"].items()},
        "srcs": [sp(s) for s in j["inputs"]["srcs"]],
        "system": j["system"], "builder": j["builder"], "args": j["args"], "env": dict(j["env"]),
    }
    h = hash_modulo(d, True, cache_dir)
    paths = {}
    for o in j["outputs"]:
        paths[o] = make_store_path(f"output:{o}", h, j["name"] if o == "out" else f"{j['name']}-{o}")
        d["outputs"][o] = (paths[o], "", "")
        d["env"][o] = paths[o]
    with open(aterm_out, "w") as f:
        f.write(unparse(d))
    print(json.dumps(paths))


main()
