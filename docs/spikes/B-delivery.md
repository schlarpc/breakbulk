# Spike B: delivery mechanics

Nov 7, 2026 · spike for M5 (dynamic-derivation delivery)

The spike's code is on the [`spikes-archive`](https://github.com/schlarpc/breakbulk/tree/spikes-archive) tag; paths below are relative to it.

**Verdict: go, with design changes.** A `builder-rpc-v0` derivation can write
input-addressed unit derivations whose paths equal the IFD-mode paths
byte for byte. It cannot do it with `nix derivation add`; it needs its own
derivation hashing, which harmonia already provides. Root submission needs a
wrapper derivation with a fixed name. Downstream stages may be CA or plain;
both work. Two statements in the design doc are wrong (details at the end).

Everything below was run on Nix master `94c011f50` (2026-11-06,
`nix (Nix) 2.36.0pre20261106_94c011f`) against a private chroot store. The
system daemon and `/etc/nix` were not touched. Confidence is high for every
claim marked "observed" and for every source citation; claims marked
"not tested" are from source reading only.

## Questions and answers

| Question | Answer |
| --- | --- |
| Is `builder-rpc-v0` real, and what is it? | Yes. A derivation system feature that gives the builder a restricted daemon socket. Commands: `nix derivation add`, `nix store add`, `nix store submit-output`. |
| Which release has it? | None. Merged to master on 2026-07-21, after the 2.35 branch point. First release: 2.36. Determinate Nix does not have it. |
| Can a `builder-rpc-v0` builder add input-addressed units with the IFD paths? | Yes (observed, 5 of 5 units identical), with harmonia or equivalent hashing code. Not with `nix derivation add`. |
| Can a root unit's `.drv` be submitted directly? | No. Nix requires the submitted path to be named `<outer name>-<output>`. A small wrapper derivation per root is needed. |
| Must a stage that depends on `outputOf` be CA? | No. A plain `derivation` becomes "deferred input-addressed" and also works. Both are resolved at build time. |
| What does resolving a stage download? | The closure of every input's output: here the wrapper's output, the root unit's output and that output's runtime closure. Not the unit's build inputs. |
| What does `post-build-hook` with `"$DRV_PATH^*"` upload? | Outputs for every derivation; build-trace entries (realisations) for CA derivations, keyed by the *resolved* derivation; and, for the outer derivation, the whole `.drv` closure of the units, which includes the source views. |

## What `builder-rpc-v0` is

Sources: [NixOS/nix](https://github.com/NixOS/nix) at `94c011f5040d8c1b1e251b17b5c79ff370208663`.

- **A system feature, not a command.** A derivation opts in with
  `requiredSystemFeatures = [ "builder-rpc-v0" ]`
  (`src/libstore/include/nix/store/derivations.hh`, `drvFeatureBuilderRpcV0`).
- **The derivation must be content-addressed.** Input-addressed is rejected
  ("The builder-rpc-v0 feature may only be used with content-addressing
  derivations", `src/libstore/unix/build/unix-derivation-builder.cc:354-357`;
  also `src/libstore/derivations.cc:394-400`). The builder gets no `$out`
  variables; outputs are submitted over RPC.
- **The socket.** Nix starts a restricted daemon and sets
  `NIX_REMOTE=unix:///build/.nix-socket` (`unix-derivation-builder.cc:686-688`;
  observed). The handshake is fixed at protocol 1.38 with features
  `realisation-with-path-not-hash`, `disable-set-options`,
  `add-to-store-scanning`, `submit-output`
  (`src/libstore/worker-protocol.cc`, `WorkerProto::builderRpcV0`).
- **Allowed operations** (`src/libstore/daemon.cc:332-347`): `AddToStore`,
  `AddMultipleToStore`, `AddToStoreNar`, `AddToStoreScanning`, `SubmitOutput`,
  `AddTempRoot`, `IsValidPath`. Nothing that reads store contents
  (`QueryPathInfo`, `NarFromPath`).
- **CLI commands** (manual, `doc/manual/source/store/building.md:229-238`):
  `nix derivation add` (JSON in, `.drv` path out), `nix store add` (with
  `--scan` for reference scanning) and `nix store submit-output <path> <output>`.
  The upstream test is `tests/functional/dyn-drv/non-trivial-submitted.nix`.
- **Advertised automatically.** Any store with the `dynamic-derivations`
  experimental feature adds `builder-rpc-v0` to its default system features
  (`src/libstore/store-api.cc:404`). Setting `system-features` in `nix.conf`
  does not remove it (observed); only a store URL parameter does.
- **Only opaque paths can be submitted**, not `drv^out` paths
  (`unix-derivation-builder.cc:801`, NixOS/nix#12727).
- **Added paths are not mounted into the sandbox.** For `builder-rpc-v0`,
  `shouldModifySandbox()` returns false
  (`src/libstore/unix/build/unix-derivation-builder-impl.hh:126`). The builder
  cannot read back what it added (observed: `cat` of an added `.drv` fails).
- **History.** Commit `55eea4554` "Implement new builder-rpc-v0 derivation
  feature" (Artemis Tosini, authored 2025-11-17), merged with PR #15793
  (`8ddb47275`, 2026-07-21). The 2.35 branch forked at `9539ea593`
  (2026-06-22); the newest tag is 2.35.4; master's `.version` is 2.36.0. So
  the first release with the feature will be 2.36.
- **Determinate Nix.** [DeterminateSystems/nix-src](https://github.com/DeterminateSystems/nix-src)
  `main` at `60ca49f` (2026-11-06) is Determinate 3.24.2 on upstream 2.35.3. It
  has no `builder-rpc-v0`, `SubmitOutput` or `submit-output` anywhere. It does
  have the `dynamic-derivations` feature and `builtins.outputOf`. The local
  Determinate 3.22.2 reports `builtins.nixVersion = "2.35.2"`.

### `builtins.outputOf` and detection

`outputOf` is registered with `.experimentalFeature = Xp::DynamicDerivations`
(`src/libexpr/primops.cc:2578-2605`), and primops with a disabled feature are
not added to `builtins` (`primops.cc:5611`). So `builtins ? outputOf` is true
exactly when the evaluator has `dynamic-derivations`. Observed with
`spikes/delivery/detect.nix`:

| Evaluator | `nixVersion` | `builtins ? outputOf` | Proposed `auto` result |
| --- | --- | --- | --- |
| Determinate 3.22.2 | 2.35.2 | false | ifd |
| Determinate 3.22.2, `dynamic-derivations` on | 2.35.2 | true | ifd |
| Nix master | 2.36.0pre20261106_94c011f | false | ifd |
| Nix master, `dynamic-derivations` on | 2.36.0pre20261106_94c011f | true | dynamic |

The version test must be `builtins.compareVersions builtins.nixVersion "2.36pre" >= 0`.
Comparing against `"2.36"` or `"2.36.0"` would reject master builds, which
report `2.36.0pre…`. This only describes the evaluator; a daemon or builder
without the feature still fails at build time, with Nix's own message:

```
error: Cannot build '/nix/store/…-breakbulk-instantiate-requires-builder-rpc-v0.drv'.
       Reason: missing system features
       Required features: {builder-rpc-v0, ca-derivations}
       Available features: {benchmark}
```

That message already names the feature, so the outer derivation's name does
not need to.

## The prototype

Everything lives in `spikes/delivery/`. `setup.sh` seeds a private store and
`nixm` runs Nix master on it. Run `./setup.sh` first.

| File | Role |
| --- | --- |
| `units.json` | Stand-in for the templater's output: five units (`a`; `b` and `c` on `a`; bins `d` and `e`), roots `app` and `tool`. References are segments: `{unit, output, file}`, `{tool}` (a toolchain derivation), `{src}` (a source view), `{product}`. |
| `ifd.nix` | IFD mode: an instantiate derivation outputs `units.json`, Nix imports it and applies `derivation` to each unit. |
| `dyn.nix` | Dynamic mode: the outer derivation (CA, text-hashed, `builder-rpc-v0`), the `linked` stage in CA and plain forms, and a second plan (`host`) that embeds the first plan's `tool` product. |
| `instantiate.sh` | The outer builder: renders references, writes each unit with one of three mechanisms (`ADD_METHOD`), wraps and submits roots. |
| `bb-drv/` | The harmonia-based writer (Rust, ~150 lines). Built with `rustPlatform` at harmonia `637dd7e`. |
| `drvhash.py` | An independent Python version of Nix's `hashDerivationModulo` and ATerm printer, used as a cross-check. |
| `cache-experiment.sh` | A producer store with a `post-build-hook`, a `file://` cache, and a fresh consumer store. `DROP_BUILD_TRACE=1` simulates a cache without realisations. |

The toolchain is passed as drv-only context (`unsafeDiscardOutputDependency`),
so the outer derivation can name it without building it. Observed: the
toolchain was built only when a unit needed it.

## Finding 1: identical unit paths, but not through `nix derivation add`

Unit `.drv` paths from both modes (observed; also equal with `ADD_METHOD=compute`):

| Unit | IFD mode | Dynamic mode (harmonia) |
| --- | --- | --- |
| `a-0.1.0-lib` | `85z32n9j…` | `85z32n9j…` |
| `b-0.1.0-lib` | `n8f80sl0…` | `n8f80sl0…` |
| `c-0.1.0-lib` | `fcgjg4qv…` | `fcgjg4qv…` |
| `app-0.1.0-bin` | `3s644sf2…` | `3s644sf2…` |
| `tool-0.1.0-bin` | `aqgc8cik…` | `aqgc8cik…` |

Output paths match too. When the dynamic build ran after an IFD build, it
rebuilt no unit; the outputs were already valid.

**`nix derivation add` fails for any unit with a unit input.** With deferred
outputs it fills in the paths itself, and the first unit (`a`, inputs only a
toolchain and a source) got the right path. The second failed:

```
error: store path '/nix/store/85z32n9j…-a-0.1.0-lib.drv' does not exist
```

The CLI validates the derivation on the client side
(`parseJsonAndValidate`, `src/libstore/derivations.cc:620`), which reads
each input `.drv` from the local filesystem. Derivations added during this
build are never mounted into the sandbox (see above). So the CLI can only
add derivations whose inputs came from outside the build. The upstream test
avoids the problem because its inner derivations are floating CA, which need
no input hashing.

**What works:** compute the output paths in the builder, print the ATerm, and
add it as a text-hashed store object.

- `ADD_METHOD=harmonia` (the default) uses `bb-drv`: harmonia's
  `fill_deferred_outputs` and `hash_input_modulo` (reading `.drv` files it
  wrote from its own cache directory, and other inputs from the store),
  `print_derivation_aterm`, then `add_ca_to_store` with
  `ContentAddressMethodAlgorithm::Text` and explicit references (input
  sources plus input `.drv` files, as `Store::writeDerivation` does), then
  `submit_output`. harmonia's client negotiates the `builder-rpc-v0` features
  (`harmonia-protocol/src/version.rs`, `builder_rpc_v0_features`;
  `harmonia-store-remote/src/client.rs:247-260`). It compiled and worked on
  the first try. The crates are MIT and versioned `0.0.0-alpha.0`, used as a
  git dependency.
- `ADD_METHOD=compute` uses `drvhash.py` and `nix store add --mode text --scan`.
  It also works, but references come from scanning rather than being stated,
  and it needs the Nix CLI inside the sandbox.
- The daemon checks the result: registering a `.drv` recomputes its
  input-addressed outputs (`src/libstore/local-store.cc:761-769`). A wrong
  hash cannot get into the store.

**A Nix quirk the templater must avoid.** If a deferred output's env var
(`out`, `rlib`, …) is *missing* instead of empty, `nix derivation add` fails
with "derivation has incorrect output … should be …" (observed, also outside
the sandbox). Fill-in hashes the derivation without the key, then inserts it,
then validation hashes it with the key. harmonia masks the same way. The rule:
always emit every output env var, set to `""`, exactly as `derivation` does.
This could be reported upstream.

**Matching `derivation` exactly.** The dynamic-mode JSON must contain what
`derivation` puts in `env`: every attribute except `args`, plus `builder`,
`name`, `system`, `outputs` (space-separated, in declaration order) and the
output variables. `inputs.srcs` must include every store path whose string
context appears in a value, such as `bash` for the builder and `coreutils` for
`PATH`. The conformance test in the implementation doc catches mistakes here.

## Finding 2: roots need a wrapper with a fixed name

Submitting the root unit's `.drv` as output `app.drv` fails:

```
error: derivation '…-breakbulk-instantiate-requires-builder-rpc-v0.drv' output 'app.drv'
(at '…-app-0.1.0-bin.drv') was named 'app-0.1.0-bin.drv',
expected 'breakbulk-instantiate-requires-builder-rpc-v0-app.drv'
```

(`src/libstore/build/derivation-check.cc:109-112`, `outputPathName(drv.name, outputName)`.)
So each root gets a wrapper: an input-addressed derivation named
`<outer name>-<root>`, depending on the root unit's `out` and symlinking it.
The wrapper's output name is what `outputOf … "out"` returns, so the outer
name shows up in product paths. This is what cargo-dyndrv's "symlink wrapper"
is for.

The outer derivation is CA, so an instantiation that writes the same units
produces the same output. Observed: adding a new tool to the outer
derivation changed its `.drv` path, but its outputs (`cny23bg8…-app.drv`,
`spix531p…-tool.drv`) stayed the same, so nothing downstream was re-resolved.

## Finding 3: stages and units downstream of `outputOf`

`linked` was built in two forms over `outputOf outer."app.drv".outPath "out"`
(observed):

- **CA** (`__contentAddressed = true`): works.
- **Plain `derivation`**: Nix makes it "deferred input-addressed" (outputs
  `{}`, `env.out = ""`), resolves it at build time, and the resolved
  derivation is input-addressed. Works.

Both record the input as a dynamic output:
`"inputs": {"drvs": {"<outer>.drv": {"outputs": [], "dynamicOutputs": {"app.drv": {"outputs": ["out"]}}}}}`.

Build order (observed): the outer derivation, the wrapper (and through it any
unit not yet valid), then the stage. Resolution first realises every input
(`src/libstore/build/derivation-resolution-goal.cc:27`, `realiseInputs`). For
`linked` the inputs are the wrapper's output, so a consumer downloads the
wrapper, the root unit's output and that output's runtime closure, then the
stage. The rlibs were downloaded in the experiment only because the fake
binaries reference them.

`queryMissing` skips dynamic derivations: "warning: Ignoring dynamic
derivation …^app.drv while querying missing paths; not yet implemented"
(`src/libstore/misc.cc:198`). So `--dry-run` and the "will be built/fetched"
summary do not cover anything behind the outer derivation.

**Embedded products** (the `host` plan). The product is the other plan's CA
`linked` stage, a static derivation. The host's outer derivation gets its
`.drv` with drv-only context and its placeholder (`outPath`, since it is CA).
Observed:

- The host plan was instantiated before the `tool` product was built. Host
  instantiation does not depend on the product, as the `embed` fixture
  requires.
- The embedding unit `f` becomes deferred: harmonia's `fill_deferred_outputs`
  returns `None` because an input is CA.
- **Every unit downstream of `f` is deferred too**, and must reference `f`'s
  outputs by placeholder (`Placeholder::ca_output(f.drv, "rlib")`), not by
  path. `g`'s written `.drv` has `("out","","","")` and an `extern` of
  `/17a7yfkv…/libembedder.rlib`; the resolved `g` has a real input-addressed
  path. The wrapper is deferred as well.
- harmonia writes these with the `DrvWithVersion("xp-dyn-drv", …)` ATerm only
  when an input is a dynamic output. Here the product is a static CA
  derivation, so plain `Derive(…)` was enough.

## Finding 4: what `post-build-hook` with `"$DRV_PATH^*"` uploads

Hook: `nix copy --to file://… "$DRV_PATH^*"` (`post-build-hook.sh`).
Observed in `cx1`/`cx2`:

| Derivation built | `DRV_PATH` given to the hook | Uploaded |
| --- | --- | --- |
| Unit (input-addressed) | the unit `.drv` | its outputs; no build-trace entry |
| Outer (CA, text) | the outer `.drv` | wrapper `.drv` files and their whole closure: every unit `.drv`, the toolchain `.drv`, the source views, and the runtime closures of `bash`/`coreutils` (sources of the unit `.drv` files); plus `build-trace-v2/<outer>.drv/app.drv.doi` and `tool.drv.doi` |
| Wrapper (input-addressed) | the wrapper `.drv` | its output |
| CA `linked` | the **resolved** `.drv` (`qwfzvsmd…`, not `drsg6hqc…`) | its output, plus `build-trace-v2/<resolved>.drv/out.doi` |
| Deferred `linked` | the resolved `.drv` | its output only |

The cache layout is `build-trace-v2/<drv path>/<output>.doi`, a JSON
`{"outPath": …, "signatures": […]}` (`binary-cache-store.hh:118`). The older
`realisations/` directory is abandoned. Determinate's code uses the same
layout.

**Consumer, cache with build traces** (`cx1`): the outer derivation is not
rebuilt. Its trace gives the wrapper `.drv`, which is downloaded with every
unit `.drv` it references. The wrapper output and its closure are downloaded,
then CA `linked` is substituted through its trace.

**Consumer, cache without build traces** (`cx3`, `cx4`, simulating Attic or
FlakeHub Cache):

- The outer derivation (instantiation) is **re-run**.
- Units and wrappers are substituted by narinfo.
- CA stages are rebuilt.
- Deferred input-addressed stages are substituted, because the resolved
  derivation is input-addressed.
- **The embedding chain is substituted, not recompiled**, as long as the
  rebuilt CA product has the same bytes: the resolved `f` and `g` have
  ordinary input-addressed paths (`3xcryw8k…-embedder-0.1.0-lib-rlib`,
  `h0is198h…-host-0.1.0-bin`, both fetched).

**Privacy.** The outer derivation's `^*` closure contains the source views,
because they are sources of the unit `.drv` files. In dynamic-derivation
mode, a hook that pushes everything pushes the workspace's sources to the
cache. In IFD mode the same hook pushes only build outputs. Users with
private code on a public cache need to know this.

## Recommendations for M5

1. **Write units with harmonia, in `breakbulk-instantiate`.** Use
   `fill_deferred_outputs`/`hash_input_modulo`, `print_derivation_aterm`,
   `add_ca_to_store` (text, explicit references) and `submit_output` over
   `$NIX_REMOTE`. Keep an in-process map from `.drv` path to ATerm, because
   the builder cannot read back what it wrote. Do not use `nix derivation add`
   (it does not work for this). No Nix CLI is needed in the sandbox.
2. **Emit the same derivation in both modes.** In IFD mode, the emitted
   attributes go through `derivation`. In dynamic mode, the emitted derivation
   must equal what `derivation` would produce: same `env` keys, empty output
   variables, sources for every string context. One way to make this hard to
   get wrong: harmonia's `Derivation` type in both modes, with IFD mode
   emitting its JSON and a small Nix function that maps that JSON to
   `derivation` attributes. Keep the planned conformance test that compares
   `.drv` paths.
3. **Track deferral.** A unit is deferred if any input is a product or a
   deferred unit. Deferred units are written with deferred outputs, and
   dependents reference them with `Placeholder::ca_output`. This affects
   rendering only in dynamic mode, and only on the embedding chain.
4. **Root wrappers.** One wrapper derivation per root, named
   `<outer name>-<root>`, symlinking the root unit's output. Choose the outer
   name for readable product paths (for example `<ws>-<triple>-<variant>`),
   since Nix's own error already explains a missing `builder-rpc-v0`.
5. **Stages.** Either form works over `outputOf`. Keep stages CA for cutoff,
   as designed. For a plain pass-through such as `linked`, a deferred
   input-addressed derivation substitutes on caches without realisations,
   where a CA one is rebuilt; the author may prefer that for `linked`.
6. **Detection.** `mode = "auto"` picks dynamic when
   `builtins ? outputOf && builtins.compareVersions builtins.nixVersion "2.36pre" >= 0`.
7. **Caching notes for users.** Pushing `"$DRV_PATH^*"` uploads source views
   in dynamic mode. On caches without build traces, instantiation re-runs on
   every consumer, but units, wrappers, deferred stages and the embedding
   chain still substitute.

## Changes needed in the docs

- **implementation.md, Dynamic-derivation mode:** "Units are added … with
  `nix derivation add`, or with harmonia's derivation types if they fit;
  spike B decides." Replace with: harmonia (hashing, ATerm,
  `AddToStore`/`SubmitOutput`); `nix derivation add` cannot add a derivation
  whose inputs were written in the same build. Add the empty-output-variable
  rule.
- **implementation.md, Dynamic-derivation mode:** "Each root is handed back
  with `nix store submit-output`, as an output named `<root>.drv`." Add the
  wrapper derivation and its naming rule. The outer derivation's name no
  longer needs to say `requires-builder-rpc-v0`: Nix's own error already
  names the missing feature.
- **implementation.md, Derivation shape:** "the reference is a placeholder
  and the referencing unit is resolved at build time too." Add: so is every
  unit downstream of it, and each such reference is a placeholder.
- **implementation.md, Mode selection:** spell the version test as
  `compareVersions nixVersion "2.36pre" >= 0` (master reports
  `2.36.0pre…`). The Determinate statement is right: it reports its upstream
  base (2.35.x) and lacks the feature.
- **implementation.md, The `linked` stage:** in dynamic mode, `linked`
  depends on the wrapper's output, which symlinks the root unit's output, so
  there are two symlink hops. Harmless, but worth a sentence.
- **design.md, Content-addressed islands and Operational notes:** "The
  embedding chain in dynamic-derivation mode is the exception: it is
  recompiled", and the advice to pin `mode = "ifd"` on FlakeHub Cache for
  that reason. Observed otherwise: the embedding units are deferred
  input-addressed, not CA, so after the CA product stage is rebuilt with the
  same bytes they substitute by narinfo. What does re-run on such caches is
  instantiation and the CA stages.
- **design.md, Operational notes:** add that `"$DRV_PATH^*"` on the
  instantiate derivation uploads source views and every unit `.drv`.
- **Both docs:** "realisations" in caches are now stored under
  `build-trace-v2/`; a cache server must serve that path.

## Not verified

- Remote builders and CI services (the "Remote builders" spike). From source,
  a remote machine must advertise `builder-rpc-v0` in its machine spec; a
  local store advertises it whenever `dynamic-derivations` is enabled.
- Speed with hundreds of units (the "Graph size" spike). `bb-drv` opens one
  daemon connection per call here; the real instantiator should keep one.
- Signed build traces and a non-`file://` cache.
- Once, a wrapper build was killed by signal 9 with an empty log; an
  identical rerun succeeded. It was probably memory pressure on the shared
  machine, but it was not investigated.
- The recursive-nix removal proposal cited in the implementation doc was not
  checked.

## Reproduce

```sh
cd spikes/delivery
./setup.sh                                   # private store under SPIKE_DIR
./nixm build -f ifd.nix roots.app roots.tool --no-link --print-out-paths
./nixm build -f dyn.nix linked.app linkedIA.app host.linked.host -L --no-link
ADD_METHOD=compute ./nixm build --impure -f dyn.nix outer -L --no-link   # cross-check with drvhash.py
./cache-experiment.sh "$SCRATCH/cx1" linked.app
DROP_BUILD_TRACE=1 ./cache-experiment.sh "$SCRATCH/cx4" host.linkedIA.host
nix-instantiate --eval --strict --json detect.nix
```

The chroot store's files are read-only; use `chmod -R u+w` before deleting it.
