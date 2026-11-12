# The linker choice ("Linker selection" in docs/src/explanation/targets.md):
# one function,
# called by every preset and by the host spec, from the target triple, the
# Rust toolchain, the LTO mode and the preset's flavor to a linker.
# `targets.<t>.linkerKind` picks another kind; `targets.<t>.linker` (or
# `host.linker`) overrides it like any preset field.
#
#   linkerKind { triple; traits ? <built-in>; lto ? false; flavor ? null;
#                kind ? null; rustc ? null; staticNonPie ? false; }
#                                                        -> a kind name
#   chooseLinker { pkgs; triple; traits; lto; flavor; kind; rustc; … }
#                                                        -> a linker path
#
# `linkerKind` is the decision, a pure function of the target's traits
# (lib/target-traits.nix; a user's `targets.<triple>.traits` included),
# what rustc itself would do (`rustc`, from `rustcFacts`), the LTO mode
# and the flavor:
#
#   kind                 default when (traits)           linker
#   zig                  flavor = "zig"                  `zig cc -target <arch>-linux-gnu.<glibc>`
#   lld-link             isMsvc                          lld-link (wrapped: reproducible PDBs)
#   wasm-component-ld    isWasm, os wasi, env p2         rustc's wasm-component-ld over wasm-ld
#   wasm-ld              other isWasm                    wasm-ld
#   mingw-lld            isMingw (windows-gnu, -gnullvm) the MinGW C driver with -fuse-ld=lld
#   clang-lld            isLinux with lto                clang with -fuse-ld=lld
#   lld                  isLinux, rustc picks lld        the wrapped cc with -fuse-ld=lld
#   cc                   other isLinux                   the wrapped cc with its own default (GNU ld)
#   mold                 never (`kind = "mold"`)         the wrapped cc with -fuse-ld=mold
#
# `kind` (`targets.<triple>.linkerKind`) replaces the default; a kind that
# cannot link for the target's traits, the LTO mode, the flavor or a
# non-PIE static executable is an evaluation error naming both.
#
# rustc's own choice on Linux (`rustcPicksLld`), read from rustc's source
# (rustc_target `spec/base/linux_gnu.rs`, `targets/x86_64_unknown_linux_gnu.rs`;
# bootstrap `core/config`, `build_steps/compile.rs`): a rustc built with
# its bundled lld as a default links through the C driver with
# `-fuse-ld=lld` and its own `rust-lld` (linker flavor gnu-lld-cc).
# Bootstrap turns that on only for a compiler whose host is
# x86_64-unknown-linux-gnu, built with its own LLVM: rust-lang's builds
# (rustup, rust-overlay, fenix), not nixpkgs' (`--disable-lld`, nixpkgs'
# LLVM). Such a compiler uses it for
#   x86_64-unknown-linux-gnu   on nightly from 1.80, on every channel from 1.90
#   every `-linux-gnu*` target from 1.92 (the base linux_gnu spec)
# and the C driver's default linker everywhere else (musl included).
#
# `isLinux` is a Linux userland; Android (the Linux kernel, its own
# userland) has no rule and fails with a message naming issue #27.
#
# Every LLVM tool (lld, wasm-ld, lld-link, clang) comes from the LLVM
# release matching rustc's (`llvm`, chosen by the preset through
# breakbulk.llvmVersions), never rustup's self-contained rust-lld. Where
# rustc's target spec names the linker flavor itself (wasm, msvc), the
# linker keeps the name that selects that flavor.
#
# Linux ELF links go through nixpkgs' wrapped cc, and the linker it runs
# through bintools-wrapper's ld-wrapper, so the wrapper's rpath,
# NIX_LDFLAGS and hardening handling apply. rustc's own lld default passes
# `-B<sysroot>/lib/rustlib/<host>/bin/gcc-ld -fuse-ld=lld` to the C driver
# (checked with rustc 1.95 and 1.99, `--print link-args`), which bypasses
# the Nix linker wrapper. The stable opt-out, `-C linker-features=-lld`, is
# a rustflag, and rustflags never reach host units, so every C-driver
# linker here (cc, lld, mold, clang-lld, mingw-lld, zig) drops those two
# arguments instead (also inside an `@file` response file), for host and
# target units alike.
{
  lib,
  util,
  targetTraits,
  toolchainFacts,
  llvmVersions,
}:
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

  # A wrapped C compiler with lld from `llvm` as `ld.lld` in its bintools,
  # behind bintools-wrapper's ld-wrapper like the bintools' own `ld`. A
  # plain symlink (as stdenvAdapters.useMoldLinker adds mold, whose package
  # is wrapped already) would skip the wrapper: no rpaths. The unprefixed
  # name is for a cross compiler, as useMoldLinker adds it.
  withLld =
    p: cc: llvm:
    let
      prefix = cc.bintools.targetPrefix;
    in
    cc.override {
      bintools = cc.bintools.override {
        extraBuildCommands = ''
          wrap ${prefix}ld.lld ${p.path}/pkgs/build-support/bintools-wrapper/ld-wrapper.sh ${llvm.lld}/bin/ld.lld
        ''
        + lib.optionalString (prefix != "") ''
          ln -s ${prefix}ld.lld $out/bin/ld.lld
        '';
      };
    };

  # nixpkgs' wrapped cc for `p`'s platform and its default linker (GNU ld).
  # Not named `cc-ld`: rustc takes a linker whose name ends in `-ld` for a
  # bare ld and passes it ld's arguments, not the C driver's
  # (rustc_target spec/mod.rs, `infer_linker_hints`).
  ccLinker =
    p:
    let
      cc = p.stdenv.cc;
      prefix = cc.targetPrefix;
    in
    driverWrapper p "${prefix}cc-default" "${cc}/bin/${prefix}cc" "";

  # nixpkgs' wrapped cc for `p`'s platform with lld from `llvm`.
  ccLldLinker =
    p: llvm:
    let
      prefix = p.stdenv.cc.targetPrefix;
    in
    driverWrapper p "${prefix}cc-lld" "${withLld p p.stdenv.cc llvm}/bin/${prefix}cc" "-fuse-ld=lld";

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
  # nixpkgs' clang wrapper has GNU binutils as its bintools, so
  # `-fuse-ld=lld` finds no `ld.lld` without `withLld`.
  lldLinker =
    p: llvm:
    let
      prefix = llvm.clang.targetPrefix;
    in
    driverWrapper p "${prefix}clang-lld" "${withLld p llvm.clang llvm}/bin/${prefix}clang" "-fuse-ld=lld";

  # lld-link, wrapped so the PDB, and so the .exe, are reproducible
  # (./lld-link-stable.sh).
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

  # What each kind links for (./linker-kinds.nix).
  linkerKinds = import ./linker-kinds.nix { inherit lib; };
  inherit (linkerKinds) kinds;
  kindNames = linkerKinds.names;

  # rustc's own linker on a Linux target: true where its target spec links
  # with its bundled lld (see the table at the top), for
  # `rustc = { version; bundledLld; host; }` (`rustcFacts`).
  rustcPicksLld =
    {
      triple,
      traits,
      rustc,
    }:
    let
      v = rustc.version;
      at = gate: util.rustVersion.atLeast gate v;
      nightly = lib.hasInfix "-nightly" v || lib.hasInfix "-dev" v;
    in
    rustc.bundledLld
    && rustc.host == "x86_64-unknown-linux-gnu"
    && traits.isLinux
    && traits.env == "gnu"
    && (at "1.92" || (triple == "x86_64-unknown-linux-gnu" && (at "1.90" || (nightly && at "1.80"))));

  defaultKind =
    {
      triple,
      traits,
      lto,
      flavor,
      rustc,
    }:
    let
      t = traits;
    in
    if flavor == "zig" then
      "zig"
    else if flavor != null then
      throw "breakbulk.presets.chooseLinker: unknown linker flavor `${flavor}`"
    else if t.isMsvc then
      "lld-link"
    else if t.isWasm && t.isWasi && t.env == "p2" then
      "wasm-component-ld"
    else if t.isWasm then
      "wasm-ld"
    else if t.isMingw then
      "mingw-lld"
    else if t.isLinux then
      (
        if lto then
          "clang-lld"
        else if rustc == null then
          throw "breakbulk.presets.chooseLinker: the default linker for `${triple}` is the one rustc picks, which depends on its release and build; pass `rustc` to the preset, or set `targets.${triple}.linkerKind`"
        else if rustcPicksLld { inherit triple traits rustc; } then
          "lld"
        else
          "cc"
      )
    else if t.os == "android" then
      throw "breakbulk.presets.chooseLinker: no linker rule for the Android target `${triple}`: Android has the Linux kernel but its own userland (bionic, the NDK's linker), which breakbulk has no preset for yet (issue #27); set `targets.${triple}.linker`"
    else
      throw "breakbulk.presets.chooseLinker: no linker rule for `${triple}`; set `targets.${triple}.linker`";

  linkerKind =
    {
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      lto ? false,
      flavor ? null,
      # The kind asked for (`targets.<triple>.linkerKind`); null: the default.
      kind ? null,
      # { version; bundledLld; host; } (`rustcFacts`), for the Linux default.
      rustc ? null,
      # The link makes non-PIE static glibc executables
      # (linuxStatic's `relocationModel = "static"`).
      staticNonPie ? false,
    }:
    let
      asked = "`linkerKind = \"${kind}\"`";
      k = kinds.${kind};
    in
    if kind == null then
      defaultKind {
        inherit
          triple
          traits
          lto
          flavor
          rustc
          ;
      }
    else if kind == "zig" then
      throw "breakbulk.presets.chooseLinker: ${asked}: zig links only for presets.linuxPortable, whose `backend = \"zig\"` sets it with the C compiler and glibc"
    else if !(kinds ? ${kind}) then
      throw "breakbulk.presets.chooseLinker: unknown linker kind `${kind}` for `${triple}`; known: ${lib.concatStringsSep ", " kindNames}"
    else if !(k.on traits) then
      throw "breakbulk.presets.chooseLinker: ${asked} links for ${k.what} targets, not for `${triple}`"
    else if flavor == "zig" then
      throw "breakbulk.presets.chooseLinker: ${asked} cannot link for `${triple}` with linuxPortable's `backend = \"zig\"`, which links with `zig cc` against its old glibc"
    else if lto && !(k.bitcode or false) then
      throw "breakbulk.presets.chooseLinker: ${asked} cannot link for `${triple}` with `crossLanguageLto`, which needs a linker that reads LLVM bitcode (`clang-lld`)"
    else if staticNonPie && kind == "mold" then
      throw "breakbulk.presets.chooseLinker: ${asked} cannot link for `${triple}` with `relocationModel = \"static\"`: mold links non-PIE static glibc Rust executables that crash at startup"
    else
      kind;

  # What `linkerKind` needs to know about `rustc`, a Rust toolchain
  # running on `pkgs`' build platform.
  rustcFacts =
    { pkgs, rustc }:
    let
      f = toolchainFacts.of {
        pkgs = pkgs.buildPackages;
        inherit rustc;
      };
    in
    {
      inherit (f) version bundledLld;
      host = targetTraits.nativeTriple pkgs.buildPackages;
    };

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
      # The target's traits (lib/target-traits.nix); default: built-in.
      traits ? targetTraits.resolve { inherit triple; },
      lto ? false,
      # null (from the traits) or "zig".
      flavor ? null,
      # The kind asked for (`targets.<triple>.linkerKind`); null: the default.
      kind ? null,
      # The Rust toolchain (rustc) that links: its release and build
      # decide the Linux default, and its LLVM the lld kinds' lld.
      rustc ? null,
      staticNonPie ? false,
      # The package set whose C toolchain drives the link (cc, lld, mold,
      # clang-lld, mingw-lld); default: pkgs.
      packageSet ? pkgs,
      # LLVM packages matching rustc (lld, clang-lld, lld-link, wasm-ld,
      # wasm-component-ld); default: from `rustc`.
      llvm ?
        if rustc == null then
          null
        else
          llvmVersions.packagesFor {
            pkgs = packageSet.buildPackages;
            inherit rustc;
          },
      # mingw-lld: the lld package.
      lld ? pkgs.buildPackages.lld,
      # zig: { cc = <zig cc wrapper>; target = "<arch>-linux-gnu.<glibc>"; }.
      zig ? null,
    }:
    let
      k = linkerKind {
        inherit
          triple
          traits
          lto
          flavor
          kind
          staticNonPie
          ;
        rustc = if rustc == null then null else rustcFacts { inherit pkgs rustc; };
      };
      bp = pkgs.buildPackages;
    in
    {
      cc = ccLinker packageSet;
      lld = ccLldLinker packageSet (needs k "rustc or llvm" llvm);
      mold = moldLinker packageSet;
      clang-lld = lldLinker packageSet (needs k "llvm" llvm);
      lld-link = lldLinkLinker bp (needs k "llvm" llvm);
      wasm-ld = "${(needs k "llvm" llvm).lld}/bin/wasm-ld";
      wasm-component-ld = componentLinker bp "${(needs k "llvm" llvm).lld}/bin/wasm-ld";
      mingw-lld = mingwLinker pkgs packageSet lld;
      zig = zigLinker pkgs (needs k "zig" zig);
    }
    .${k};
in
{
  inherit
    chooseLinker
    linkerKind
    kindNames
    rustcFacts
    driverWrapper
    moldLinker
    lldLinker
    ;
}
