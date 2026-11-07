# Decision log: pending entries

Entries written while the author reviews `decision-log.md`. They will be
moved into it afterwards, keeping these numbers.

## 98. FYI: milestone M7's later targets work

wasm32-wasip2, riscv64 Linux, Windows via MinGW (`windows-gnu` and
`windows-gnullvm`) and a zig preset that targets glibc 2.17 all build, and
their tests pass under their runners (wasmtime, qemu, wine). Windows MinGW
and zig outputs rebuild byte-identically. riscv64 needs no new preset;
`linuxGnu` with that triple works, `-sys` crates included. Building the
standard library from source (`-Zbuild-std`) doesn't plan yet: Cargo wants
the standard library's own crates.io dependencies, which breakbulk doesn't
vendor. The fix is described in the implementation doc. Darwin has notes
only (no Mac builders).

## 99. ASK: C libraries for wasip2

The design said to turn off Rust's bundled copy of the WASI C library so C
headers and library match. On wasip2 that switch also removes the program's
start-up code, so nothing links. Instead, breakbulk puts nixpkgs' copy first
and swaps in its start-up files. Alternative: leave Rust's copy alone,
simpler but with mismatched C headers and library versions.

## 100. ASK: where wasip2 command-line programs are installed

All wasm targets install into `pkg/`. For wasip2 programs meant to run
under wasmtime, `bin/` would be more natural. Default: keep `pkg/`;
switching is a small change to the install step.

## 101. ASK: Windows MinGW programs link their runtime statically

Otherwise the `.exe` needs a GCC runtime DLL that isn't shipped next to it,
so it won't run on its own (or under wine). Default: static.

## 102. ASK: the zig preset and native libraries

zig targets an old glibc (2.17), but native libraries from nixpkgs (openssl
and so on) are built against a new glibc, which defeats the purpose. The
preset is meant for projects whose C code is bundled. Should breakbulk warn
when a package on a zig target declares native inputs? Default: document
only.

## 103. ASK: zig tests don't prove the program runs on old glibc

zig-built programs ask for the standard Linux loader path, which the Nix
sandbox doesn't have, so tests run them through the build machine's newer
glibc. That works (glibc is backward compatible) but doesn't prove the
program runs on glibc 2.17; only a symbol-version check does that today.
Option: run tests in a container or VM with an old glibc (heavy).
Default: symbol-version check only.

## 104. FYI: field trials on your repositories: datboi2 builds end to end

Full write-up: `docs/field-trials.md`. On read-only copies:
- **datboi2** (11 workspaces, a nightly workspace with git dependencies,
  8 wasm components, 4 embedded products) builds end to end, and the
  checks its CI runs pass from `repo.checks`. This meets M4's exit
  criterion. Cold build of the main binary: breakbulk 532 s vs crane 969 s
  (crane's number includes its extra check/test passes; vs crane's build
  alone breakbulk is ~1.2×). One-line edit to the leaf binary: 40 s vs
  206 s. Busy machine, single runs.
- **kmsrsos** builds for native, static musl and Windows x86_64/aarch64;
  build, clippy and tests pass.
- **mtgac** partly works (see 108 and 110).
Eight breakbulk bugs were found and fixed, each with a regression check.

## 105. ASK: use the Linux preset by default for the native target

Without a preset, the native target links with rustc's bundled linker and
skips nixpkgs' linker wrapper; every trial had to add `presets.linuxGnu`.
The design already says the linker choice is automatic. Proposed: the
native target gets `linuxGnu` unless you set another preset. Rebuilds every
native crate once.

## 106. ASK: the curated `-sys` defaults switch crates to system libraries

Some curated defaults (copied from nixpkgs) set variables like
`LIBSQLITE3_SYS_USE_PKG_CONFIG`, which silently swap a crate's bundled C
library (for example rusqlite's `bundled` feature) for nixpkgs' copy. That
changes what gets built behind your back. Proposed: drop those switches
from the defaults, keep the library inputs.

## 107. ASK: native libraries for binaries that link a `-sys` crate

A package's native inputs reach only that package's own build steps. When
a `-sys` crate prints just `-lmagic` (no search path), the final binary's
link step, which belongs to another package, can't find the library;
datboi2 needed `MAGIC_DIR` set by hand. Options: (a) pass each package's
library search paths along to every binary that depends on it (closest to
how it works locally); (b) keep it per package and document. Needs your
call.

## 108. ASK: check variants without `--all-targets`

Check and clippy variants always check all targets (entry 75). mtgac's wasm
check gate doesn't, so it fails under breakbulk. Proposed: an `allTargets`
switch on variants, default on.

## 109. FYI: other gaps from the trials, by priority

Listed at the end of `docs/field-trials.md`. The main ones: variants and
test plans can't be narrowed to one target; only the default variant's
tests reach `repo.checks`; modules don't receive `root` or the repository
object; first evaluation in import-from-derivation mode is slow (~4 min
for datboi2, mostly fetching crates one by one); the "no source
references" check doesn't look for toolchain paths; no per-package
feature powerset.

## 110. ASK: embedding a product at a fixed path in the source

mtgac's UI is embedded with rust-embed, which reads files from a fixed
path relative to the source rather than from an environment variable.
breakbulk can pass products only through environment variables. Option:
let a package place a product at a path inside its source view (only that
package's build steps would change). Default: not implemented yet.
