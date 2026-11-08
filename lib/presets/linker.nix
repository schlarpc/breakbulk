# The linker choice ("Linker selection" in docs/design.md): one function,
# called by every preset and by the host spec, from the target triple, the
# LTO mode and the preset's flavor to a linker. `targets.<t>.linker` (or
# `host.linker`) overrides it like any preset field.
#
#   linkerKind { triple; lto ? false; flavor ? null; }   -> a kind name
#   chooseLinker { pkgs; triple; lto; flavor; … }        -> a linker path
#
# `linkerKind` is the decision, a pure function of strings:
#
#   kind                 when                            linker
#   zig                  flavor = "zig"                  `zig cc -target <arch>-linux-gnu.<glibc>`
#   lld-link             *-pc-windows-msvc               lld-link (wrapped: reproducible PDBs)
#   wasm-component-ld    wasm32-wasip2                   rustc's wasm-component-ld over wasm-ld
#   wasm-ld              other wasm32/wasm64             wasm-ld
#   mingw-lld            *-windows-gnu, *-windows-gnullvm the MinGW C driver with -fuse-ld=lld
#   clang-lld            ELF (Linux) with lto            clang with -fuse-ld=lld
#   mold                 ELF (Linux)                     the wrapped cc with -fuse-ld=mold
#
# Every LLVM tool (lld, wasm-ld, lld-link, clang) comes from the LLVM
# release matching rustc's (`llvm`, chosen by the preset through
# breakbulk.llvmVersions), never rustup's self-contained rust-lld. Where
# rustc's target spec names the linker flavor itself (wasm, msvc), the
# linker keeps the name that selects that flavor.
#
# Linux ELF links go through nixpkgs' wrapped cc, so the wrapper's rpath,
# NIX_LDFLAGS and hardening handling apply. rustc (1.90 and later) links
# x86_64-unknown-linux-gnu with its bundled rust-lld by default: it passes
# `-B<sysroot>/lib/rustlib/<host>/bin/gcc-ld -fuse-ld=lld` to the C driver
# (checked with rustc 1.95 and 1.99, `--print link-args`), which bypasses
# the Nix linker wrapper. The stable opt-out, `-C linker-features=-lld`, is
# a rustflag, and rustflags never reach host units, so every C-driver
# linker here (mold, clang-lld, mingw-lld, zig) drops those two arguments
# instead (also inside an `@file` response file), for host and target
# units alike.
{ lib }:
let
  # A C compiler driver wrapper that drops rustc's self-contained-lld
  # arguments and adds `flag`. Runs on `p`'s build platform.
  driverWrapper =
    p: name: exe: flag:
    "${p.buildPackages.writeShellScriptBin name ''
      drop() {
        case "$1" in
        -fuse-ld=lld | -B*/lib/rustlib/*/bin/gcc-ld) return 0 ;;
        esac
        return 1
      }
      args=()
      for a in "$@"; do
        if [[ $a == @* && -f ''${a#@} ]]; then
          rsp="''${TMPDIR:-/tmp}/${name}-$$-''${#args[@]}.rsp"
          while IFS= read -r line || [[ -n $line ]]; do
            drop "$line" || printf '%s\n' "$line"
          done < "''${a#@}" > "$rsp"
          args+=("@$rsp")
        elif ! drop "$a"; then
          args+=("$a")
        fi
      done
      exec ${exe} ${flag} "''${args[@]}"
    ''}/bin/${name}";

  # nixpkgs' wrapped cc for `p`'s platform, with mold in its bintools
  # (stdenvAdapters.useMoldLinker), and `-fuse-ld=mold`.
  moldLinker =
    p:
    let
      cc = (p.stdenvAdapters.useMoldLinker p.stdenv).cc;
      prefix = cc.targetPrefix;
    in
    driverWrapper p "${prefix}cc-mold" "${cc}/bin/${prefix}cc" "-fuse-ld=mold";

  # clang linking with lld from `llvm`, for cross-language LTO
  # (`-Clinker-plugin-lto`), where the linker must read rustc's LLVM bitcode.
  lldLinker =
    p: llvm:
    let
      cc = llvm.clang;
      prefix = cc.targetPrefix;
    in
    driverWrapper p "${prefix}clang-lld" "${cc}/bin/${prefix}clang" "-fuse-ld=lld";

  # lld-link, wrapped so the PDB, and so the .exe, are reproducible
  # (./lld-link-stable.sh, docs/spikes/msvc.md).
  lldLinkLinker =
    bp: llvm:
    "${
      bp.writeShellScriptBin "lld-link-stable" (
        ''
          LLD_LINK=${llvm.lld}/bin/lld-link
        ''
        + builtins.readFile ./lld-link-stable.sh
      )
    }/bin/lld-link-stable";

  # rustc's wasm-component-ld (the linker wasm32-wasip2's target spec
  # names, shipped in the toolchain's lib/rustlib/<host>/bin) with the
  # version-matched `wasm-ld` underneath instead of rustup's rust-lld.
  # Named wasm-component-ld so rustc keeps the target's wasm-lld flavor.
  # rustc puts its own lib/rustlib/<host>/bin first on the linker's PATH
  # (rustc_codegen_ssa back/linker.rs, get_linker), so the real
  # wasm-component-ld is found there whatever toolchain is in use.
  componentLinker =
    bp: wasmLd:
    "${bp.writeShellScriptBin "wasm-component-ld" ''
      self=$(readlink -f "$0")
      real=
      IFS=: read -ra dirs <<< "''${PATH:-}"
      for d in "''${dirs[@]}"; do
        if [[ -x $d/wasm-component-ld && $(readlink -f "$d/wasm-component-ld") != "$self" ]]; then
          real=$d/wasm-component-ld
          break
        fi
      done
      if [[ -z $real ]]; then
        echo "breakbulk wasip2 preset: no wasm-component-ld on PATH; the Rust toolchain ships it in lib/rustlib/<host>/bin (rustup's and rust-overlay's do)" >&2
        exit 1
      fi
      # Last: rustc's `-flavor wasm` must stay the first arguments.
      exec "$real" "$@" --wasm-ld-path ${wasmLd}
    ''}/bin/wasm-component-ld";

  # The MinGW C driver with lld. lld's GNU driver switches to its MinGW
  # driver for PE emulations (lld/tools/lld/lld.cpp); the driver finds
  # `ld.lld` through `-B`. `--no-insert-timestamp` keeps the PE header's
  # time stamp at 0: lld's MinGW driver leaves it to lld-link, which stamps
  # the current time (lld/MinGW/Driver.cpp, OPT_no_insert_timestamp).
  # The `ld.lld` drops `-pie`: GCC 15+ is configured with default PIE and
  # passes it to the linker for executables (its link spec:
  # `%{static|shared|r:;!no-pie:-pie}`); GNU ld takes it for PE as
  # --dynamicbase, lld's MinGW driver rejects it. lld's MinGW driver uses
  # --dynamicbase by default, and rustc passes it too.
  mingwLinker =
    pkgs: tp: lld:
    let
      cc = tp.stdenv.cc;
      prefix = cc.targetPrefix;
      driver = if cc.isClang then "clang" else "gcc";
      ldLld = pkgs.buildPackages.writeShellScriptBin "ld.lld" ''
        args=()
        for a in "$@"; do
          [[ $a == -pie ]] || args+=("$a")
        done
        exec ${lld}/bin/ld.lld "''${args[@]}"
      '';
    in
    driverWrapper tp "${prefix}${driver}-lld" "${cc}/bin/${prefix}cc" (
      lib.concatStringsSep " " [
        "-fuse-ld=lld"
        "-B${ldLld}/bin"
        "-Wl,--no-insert-timestamp"
      ]
    );

  # zig links with its own lld; the wrapper only drops rustc's
  # self-contained-lld arguments.
  zigLinker = pkgs: zig: driverWrapper pkgs "zig-cc-link-${zig.target}" zig.cc "";

  linkerKind =
    {
      triple,
      lto ? false,
      flavor ? null,
    }:
    let
      has = re: builtins.match re triple != null;
    in
    if flavor == "zig" then
      "zig"
    else if flavor != null then
      throw "breakbulk.presets.chooseLinker: unknown linker flavor `${flavor}`"
    else if has ".*-pc-windows-msvc" then
      "lld-link"
    else if triple == "wasm32-wasip2" then
      "wasm-component-ld"
    else if has "wasm(32|64)-.*" then
      "wasm-ld"
    else if has ".*-windows-gnu(llvm)?" then
      "mingw-lld"
    else if has ".*-linux-.*" then
      (if lto then "clang-lld" else "mold")
    else
      throw "breakbulk.presets.chooseLinker: no linker rule for `${triple}`; set `targets.${triple}.linker`";

  needs =
    kind: what: v:
    if v == null then
      throw "breakbulk.presets.chooseLinker: the `${kind}` linker needs `${what}`"
    else
      v;

  chooseLinker =
    {
      # The preset's package set; its buildPackages run the wrappers.
      pkgs,
      triple,
      lto ? false,
      # null (from the triple) or "zig".
      flavor ? null,
      # The package set whose C toolchain drives the link (mold, clang-lld,
      # mingw-lld); default: pkgs.
      packageSet ? pkgs,
      # LLVM packages matching rustc (clang-lld, lld-link, wasm-ld,
      # wasm-component-ld).
      llvm ? null,
      # mingw-lld: the lld package.
      lld ? pkgs.buildPackages.lld,
      # zig: { cc = <zig cc wrapper>; target = "<arch>-linux-gnu.<glibc>"; }.
      zig ? null,
    }:
    let
      kind = linkerKind { inherit triple lto flavor; };
      bp = pkgs.buildPackages;
    in
    {
      mold = moldLinker packageSet;
      clang-lld = lldLinker packageSet (needs kind "llvm" llvm);
      lld-link = lldLinkLinker bp (needs kind "llvm" llvm);
      wasm-ld = "${(needs kind "llvm" llvm).lld}/bin/wasm-ld";
      wasm-component-ld = componentLinker bp "${(needs kind "llvm" llvm).lld}/bin/wasm-ld";
      mingw-lld = mingwLinker pkgs packageSet lld;
      zig = zigLinker pkgs (needs kind "zig" zig);
    }
    .${kind};
in
{
  inherit
    chooseLinker
    linkerKind
    driverWrapper
    moldLinker
    lldLinker
    ;
}
