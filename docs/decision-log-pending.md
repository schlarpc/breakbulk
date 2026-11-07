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
