# The linker choice ("Linker selection" in docs/src/explanation/targets.md):
# one function,
# called by every preset and by the workspace's host spec, from the target triple, the
# Rust toolchain and the LTO mode to a linker, of a kind from a table a
# user or a preset can add to (`targets.<t>.linkerKinds`, starting from
# `builtinKinds` below). `targets.<t>.linkerKind` picks another kind;
# `targets.<t>.linker` (or `workspaces.<ws>.host.linker`) overrides it like any preset
# field.
#
#   linkerKind { triple; traits ? <built-in>; lto ? false; kind ? null;
#                rustc ? null; staticNonPie ? false; zig ? null;
#                ndk ? null; kinds ? builtinKinds; }     -> a kind name
#   chooseLinker { pkgs; triple; traits; lto; kind; kinds; facts; … }
#                                                        -> a linker path
#
# `linkerKind` is the decision, a pure function of the target's traits
# (lib/target-traits.nix; a user's `targets.<triple>.traits` included),
# what rustc itself would do (`rustc`, from `rustcFacts`: the toolchain's
# facts, lib/toolchain-facts.nix) and the LTO mode:
#
#   kind                 default when (traits)           linker
#   zig                  never (presets.linuxPortable)   `zig cc -target <arch>-linux-<abi>.<glibc>`
#   lld-link             isMsvc, isUefi                  lld-link (wrapped: reproducible PDBs)
#   wasm-component-ld    isWasm, os wasi, env p2         rustc's wasm-component-ld over wasm-ld
#   wasm-ld              other isWasm                    wasm-ld
#   mingw-lld            isMingw (windows-gnu, -gnullvm) the MinGW C driver with -fuse-ld=lld,
#                                                        lld of rustc's LLVM major
#   rust-lld             isApple, a Linux build machine, the toolchain's own rust-lld as ld64.lld
#                        rustc ships rust-lld
#                        isBareMetal, rustc ships    the toolchain's own rust-lld (gnu
#                        rust-lld                    flavor), as rustc's target spec does
#   ld64.lld             isApple, a Linux build machine, nixpkgs' lld as ld64.lld, of
#                        rustc ships none            rustc's LLVM major
#   ld.lld               isBareMetal, rustc ships    nixpkgs' ld.lld of rustc's LLVM major
#                        no rust-lld
#   clang-lld            isLinux with lto                clang with -fuse-ld=lld
#   lld                  isLinux, rustc picks lld        the wrapped cc with -fuse-ld=lld
#                                                        (reads bitcode too: lto)
#   cc                   other isLinux                   the wrapped cc with its own default (GNU ld)
#   ndk                  isAndroid                       the NDK's clang (`--target=<ndkTriple><api>`)
#                                                        with the NDK's lld (presets.android)
#   mold                 never (`kind = "mold"`)         the wrapped cc with -fuse-ld=mold
#
# `kind` (`targets.<triple>.linkerKind`) replaces the default; a kind that
# cannot link for the target's traits (`on`), the LTO mode (`bitcode`)
# or the link's context (`incompatible`: mold with a non-PIE static
# executable, zig outside linuxPortable) is an evaluation error naming
# both.
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
# userland) has a rule of its own: the NDK's clang, which presets.android
# gives the kind (`ndk`), as presets.linuxPortable gives zig.
#
# Apple targets: the rule is keyed on the build machine (`rustc.host`).
# From a Linux build machine rustc links directly with an ld64.lld (its
# `darwin` lld flavor, `-syslibroot` from `SDKROOT`): the toolchain's own
# rust-lld when it ships one (a rust-lang build, `bundledLld`), whose LLVM
# is rustc's, as `-C linker-plugin-lto` needs; else nixpkgs' lld of
# rustc's LLVM major. A Mac build machine has no rule yet (issue #13).
# What an SDK asks of the linker is a second, separate fact
# (`linkerFeatures` below, lib/apple-sdk.nix's `requirements`), checked by
# presets.darwin; a linker that lacks it is an error, never a silent switch
# to the other kind.
#
# Every LLVM tool (lld, wasm-ld, lld-link, clang) comes from the LLVM
# release matching rustc's (`llvm`, the toolchain facts' `llvmPackages`),
# never rustup's self-contained rust-lld. Where
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

  # A C compiler driver as a linker (`breakbulk.presets.ccDriverLinker`,
  # for the `build` of a C-driver linker kind): `exe` (default: `cc`'s
  # `<prefix>cc`; `cc` default: `packageSet`'s wrapped C compiler) with
  # `flag`, run through `driverWrapper`: a plain driver path would get
  # rustc's `-fuse-ld=lld -B…/gcc-ld` on Linux and bypass nixpkgs' linker
  # wrapper. The cc, lld and mold kinds are `cc`'s default linker (GNU
  # ld), `withLld` and `useMoldLinker`'s mold. Its name, by default
  # `<prefix>cc-<the -fuse-ld value, or default>`, must not end in `-ld`:
  # rustc takes such a linker for a bare ld and passes it ld's arguments,
  # not the C driver's (rustc_target spec/mod.rs, `infer_linker_hints`).
  ccDriverLinker =
    {
      packageSet,
      flag ? "",
      cc ? packageSet.stdenv.cc,
      exe ? "${cc}/bin/${cc.targetPrefix}cc",
      name ? "${cc.targetPrefix}cc-${
        if lib.hasPrefix "-fuse-ld=" flag then lib.removePrefix "-fuse-ld=" flag else "default"
      }",
    }:
    driverWrapper packageSet name exe flag;

  # clang linking with lld from `llvm`, for cross-language LTO
  # (`-Clinker-plugin-lto`), where the linker must read rustc's LLVM bitcode.
  # nixpkgs' clang wrapper has GNU binutils as its bintools, so
  # `-fuse-ld=lld` finds no `ld.lld` without `withLld`.
  lldLinker =
    p: llvm:
    let
      prefix = llvm.clang.targetPrefix;
    in
    ccDriverLinker {
      packageSet = p;
      name = "${prefix}clang-lld";
      exe = "${withLld p llvm.clang llvm}/bin/${prefix}clang";
      flag = "-fuse-ld=lld";
    };

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
    ccDriverLinker {
      packageSet = tp;
      inherit cc;
      name = "${prefix}${driver}-lld";
      flag = lib.concatStringsSep " " [
        "-fuse-ld=lld"
        "-B${ldLld}/bin"
        "-Wl,--no-insert-timestamp"
      ];
    };

  # zig links with its own lld; the wrapper drops rustc's
  # self-contained-lld arguments, and the inner script makes a library
  # that another library's pkg-config file names without a path (libidn2's
  # `Libs.private: -lunistring`, which pkg-config-rs passes as a plain
  # `-l` when it finds no archive on the paths pkg-config printed) link as
  # with GNU ld behind nixpkgs' cc-wrapper:
  #  - the `-L` directories of the env capture's NIX_LDFLAGS are added, as
  #    cc-wrapper adds them;
  #  - rustc's `-Wl,-Bdynamic` becomes `-Wl,-search_paths_first`: GNU ld's
  #    -Bdynamic takes an archive where a directory has no shared library,
  #    zig's does not (`lib_search_strategy = .no_fallback`, zig 0.17.0
  #    src/main.zig), while -search_paths_first does.
  zigLinker =
    pkgs: zig:
    ccDriverLinker {
      packageSet = pkgs;
      name = "zig-cc-link-${zig.target}";
      exe = pkgs.buildPackages.writeShellScript "zig-cc-search-path" ''
        dynamic=-Wl,-Bdynamic
        args=()
        for a in "$@"; do
          if [[ $a == @* && -f ''${a#@} ]]; then
            # driverWrapper's own copy of rustc's response file.
            ${pkgs.buildPackages.gnused}/bin/sed -i "s/^$dynamic\$/-Wl,-search_paths_first/" "''${a#@}"
            args+=("$a")
          elif [[ $a == "$dynamic" ]]; then
            args+=(-Wl,-search_paths_first)
          else
            args+=("$a")
          fi
        done
        for f in ''${NIX_LDFLAGS-}; do
          [[ $f == -L* ]] && args+=("$f")
        done
        exec ${zig.cc} "''${args[@]}"
      '';
    };

  # The toolchain's own rust-lld. rustc puts its lib/rustlib/<host>/bin
  # first on the linker's PATH (rustc_codegen_ssa back/linker.rs,
  # get_linker), so the wrapper finds the rust-lld of the rustc that runs
  # it; a path into the toolchain would assume one layout, and fenix's
  # and other wrapped toolchains keep the sysroot elsewhere. Named
  # rust-lld so that rustc calls it as lld (rustc_target spec/mod.rs,
  # `infer_linker_hints`) with `-flavor darwin`.
  rustLldLinker =
    bp:
    "${bp.writeShellScriptBin "rust-lld" ''
      self=$(readlink -f "$0")
      IFS=: read -ra dirs <<< "''${PATH:-}"
      for d in "''${dirs[@]}"; do
        if [[ -x $d/rust-lld && $(readlink -f "$d/rust-lld") != "$self" ]]; then
          exec "$d/rust-lld" "$@"
        fi
      done
      echo "breakbulk: no rust-lld on PATH; the Rust toolchain ships it in lib/rustlib/<host>/bin (rustup's and rust-overlay's do); set \`linkerKind\` to \"ld64.lld\" (Apple) or \"ld.lld\" (bare metal) for nixpkgs' lld instead, or the toolchain's \`facts.bundledLld = false\`" >&2
      exit 1
    ''}/bin/rust-lld";

  # nixpkgs' lld as ld64.lld: through `lld`, whose name makes rustc call it
  # with `-flavor darwin`; rustc infers nothing from the name `ld64.lld`
  # and would call it as a C compiler.
  ld64LldLinker = llvm: "${llvm.lld}/bin/lld";

  # What an Apple SDK may ask of its linker (lib/apple-sdk.nix,
  # `requirements`), and which LLD has it: from LLD release `lld` on, or
  # with a nixpkgs patch to its LLVM whose file name contains
  # `nixpkgsPatch` (nixpkgs backports some to older majors).
  linkerFeatures = {
    "arm64e.x1" = {
      what = "the arm64e.x1 CPU subtype in the SDK's .tbd stub files (llvm/llvm-project#222721)";
      lld = "23.1.3";
      nixpkgsPatch = "arm64e_x1";
    };
  };

  # Whether `lld` (a kind's `lld` result) has feature `f` (a name in
  # linkerFeatures).
  lldHas =
    lld: f:
    let
      feat =
        linkerFeatures.${f}
          or (throw "breakbulk.presets: unknown linker feature `${f}`; known: ${lib.concatStringsSep ", " (lib.attrNames linkerFeatures)}");
    in
    lib.versionAtLeast lld.version feat.lld || lib.any (lib.hasInfix feat.nixpkgsPatch) lld.patches;

  needs =
    kind: what: v:
    if v == null then
      throw "breakbulk.presetHelpers.chooseLinker: the `${kind}` linker needs `${what}`"
    else
      v;

  # The linker kinds, the table `targets.<triple>.linkerKinds` starts
  # from (a user or a preset adds to it there). Each kind:
  #
  #   on            traits -> whether it links for the target
  #   what          the targets `on` accepts, for messages
  #   bitcode       it reads rustc's LLVM bitcode (`-C linker-plugin-lto`)
  #   incompatible  ctx -> null, or why it cannot link in that context
  #                 (ctx: { triple; traits; lto; staticNonPie; zig; ndk; })
  #   build         args -> the linker, a path (args: { pkgs; packageSet;
  #                 llvm; lld; zig; ndk; triple; traits; }, `packageSet` the one
  #                 whose C toolchain drives the link, `llvm` nixpkgs'
  #                 LLVM of rustc's major)
  #   lld           null, or args -> { name; version; patches; }: the LLD
  #                 it links with, for an Apple SDK's requirements (args:
  #                 { rustc; llvm; }, `rustc` from rustcFacts)
  builtinKinds = {
    cc = {
      on = t: t.isLinux;
      what = "Linux";
      build = a: ccDriverLinker { inherit (a) packageSet; };
    };
    lld = {
      on = t: t.isLinux;
      what = "Linux";
      bitcode = true;
      build =
        a:
        ccDriverLinker {
          inherit (a) packageSet;
          cc = withLld a.packageSet a.packageSet.stdenv.cc (needs "lld" "llvm" a.llvm);
          flag = "-fuse-ld=lld";
        };
    };
    mold = {
      on = t: t.isLinux;
      what = "Linux";
      incompatible =
        ctx:
        if ctx.staticNonPie then
          "mold links non-PIE static glibc Rust executables that crash at startup (`relocationModel = \"static\"`)"
        else
          null;
      build =
        a:
        ccDriverLinker {
          inherit (a) packageSet;
          cc = (a.packageSet.stdenvAdapters.useMoldLinker a.packageSet.stdenv).cc;
          flag = "-fuse-ld=mold";
        };
    };
    clang-lld = {
      on = t: t.isLinux;
      what = "Linux";
      bitcode = true;
      build = a: lldLinker a.packageSet (needs "clang-lld" "llvm" a.llvm);
    };
    zig = {
      on = t: t.isLinux && t.env == "gnu";
      what = "Linux -gnu";
      incompatible =
        ctx:
        if ctx.zig == null then
          "zig links only for presets.linuxPortable, which sets it with the C compiler and glibc"
        else
          null;
      build = a: zigLinker a.pkgs a.zig;
    };
    # The NDK's clang driver, which links with the NDK's lld against the
    # sysroot of the API level in its `--target`. Not nixpkgs' wrapped cc:
    # its ld-wrapper adds store rpaths and its libc's dynamic linker, which
    # an Android program must not name. Always with a build ID, as the
    # NDK's own build systems (ndk-build, its CMake toolchain) link: Play
    # Console and crash reporters match symbol files by it.
    ndk = {
      on = t: t.isAndroid;
      what = "Android";
      build =
        a:
        if a.ndk == null then
          throw "breakbulk.presetHelpers.chooseLinker: `${a.triple}` links with the Android NDK's clang; use `breakbulk.presets.android { ndk = …; }`, which gives it"
        else
          ccDriverLinker {
            packageSet = a.pkgs;
            name = "${a.ndk.target}-clang";
            exe = a.ndk.clang;
            flag = "--target=${a.ndk.target} -Wl,--build-id=sha1";
          };
    };
    lld-link = {
      on = t: t.isMsvc || t.isUefi;
      what = "Windows -msvc and UEFI";
      bitcode = true;
      build = a: lldLinkLinker a.pkgs.buildPackages (needs "lld-link" "llvm" a.llvm);
    };
    wasm-ld = {
      on = t: t.isWasm && !t.linksComponents;
      what = "wasm core modules (not wasm32-wasip2)";
      bitcode = true;
      build = a: "${(needs "wasm-ld" "llvm" a.llvm).lld}/bin/wasm-ld";
    };
    wasm-component-ld = {
      on = t: t.linksComponents;
      what = "wasm components (wasm32-wasip2)";
      bitcode = true;
      build =
        a:
        componentLinker a.pkgs.buildPackages "${(needs "wasm-component-ld" "llvm" a.llvm).lld}/bin/wasm-ld";
    };
    mingw-lld = {
      on = t: t.isMingw;
      what = "Windows -gnu and -gnullvm";
      build =
        a:
        mingwLinker a.pkgs a.packageSet (
          if a.lld != null then a.lld else (needs "mingw-lld" "llvm" a.llvm).lld
        );
    };
    rust-lld = {
      on = t: t.isApple || t.isBareMetal;
      what = "Apple and bare-metal";
      build = a: rustLldLinker a.pkgs.buildPackages;
      lld = a: {
        name = "rust-lld of rustc ${a.rustc.version}";
        version = a.rustc.llvmVersion;
        patches = [ ];
      };
    };
    # nixpkgs' lld for a bare-metal target, whose rustc spec links with
    # lld directly (linker flavor gnu-lld): `ld.lld`, a name rustc and
    # lld both take for the GNU flavor (rustc_target spec/mod.rs,
    # `infer_linker_hints`; lld's driver reads its argv[0]).
    "ld.lld" = {
      on = t: t.isBareMetal;
      what = "bare-metal";
      bitcode = true;
      build = a: "${(needs "ld.lld" "llvm" a.llvm).lld}/bin/ld.lld";
    };
    "ld64.lld" = {
      on = t: t.isApple;
      what = "Apple";
      build = a: ld64LldLinker (needs "ld64.lld" "llvm" a.llvm);
      lld = a: {
        name = "nixpkgs' lld";
        version = a.llvm.lld.version;
        patches = map (p: baseNameOf (toString p)) (a.llvm.libllvm.patches or [ ]);
      };
    };
  };
  # A kind with every field.
  kindDefaults = {
    what = "some";
    bitcode = false;
    incompatible = _: null;
    lld = null;
  };
  kindsOf = lib.mapAttrs (_: k: kindDefaults // k);

  # The LLD an Apple linker kind links with: { name; version; patches; }.
  lldOf =
    {
      kind,
      # `rustcFacts`.
      rustc ? null,
      llvm ? null,
      kinds ? builtinKinds,
    }:
    let
      k = (kindsOf kinds).${kind} or { lld = null; };
    in
    if k.lld == null then
      throw "breakbulk.presetHelpers.lldOf: `${kind}` is not a linker kind that names its LLD (an Apple one)"
    else
      k.lld { inherit rustc llvm; };

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
      nightly = util.rustVersion.isNightly v;
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
      rustc,
    }:
    let
      t = traits;
    in
    if t.isMsvc || t.isUefi then
      "lld-link"
    else if t.linksComponents then
      "wasm-component-ld"
    else if t.isWasm then
      "wasm-ld"
    else if t.isMingw then
      "mingw-lld"
    else if t.isApple then
      (
        if rustc == null then
          throw "breakbulk.presetHelpers.chooseLinker: the default linker for `${triple}` depends on whether rustc ships its own rust-lld; give the toolchain's facts, or set `targets.${triple}.linkerKind`"
        else if (targetTraits.resolve { triple = rustc.host; }).isApple then
          throw "breakbulk.presetHelpers.chooseLinker: no linker rule for `${triple}` on a Mac build machine yet (issue #13); set `targets.${triple}.linker`"
        else if rustc.bundledLld then
          "rust-lld"
        else
          "ld64.lld"
      )
    else if t.isBareMetal then
      (
        if rustc == null then
          throw "breakbulk.presetHelpers.chooseLinker: the default linker for `${triple}` depends on whether rustc ships its own rust-lld; give the toolchain's facts, or set `targets.${triple}.linkerKind`"
        else if rustc.bundledLld then
          "rust-lld"
        else
          "ld.lld"
      )
    else if t.isLinux then
      (
        if lto then
          "clang-lld"
        else if rustc == null then
          throw "breakbulk.presetHelpers.chooseLinker: the default linker for `${triple}` is the one rustc picks, which depends on its release and build; give the toolchain's facts, or set `targets.${triple}.linkerKind`"
        else if rustcPicksLld { inherit triple traits rustc; } then
          "lld"
        else
          "cc"
      )
    else if t.isAndroid then
      "ndk"
    else
      throw "breakbulk.presetHelpers.chooseLinker: no linker rule for `${triple}`; set `targets.${triple}.linker`";

  linkerKind =
    {
      triple,
      traits ? targetTraits.resolve { inherit triple; },
      lto ? false,
      # The kind asked for (`targets.<triple>.linkerKind`); null: the default.
      kind ? null,
      # { version; bundledLld; host; } (`rustcFacts`), for the Linux default.
      rustc ? null,
      # The link makes non-PIE static glibc executables
      # (linuxStatic's `relocationModel = "static"`).
      staticNonPie ? false,
      # zig: { cc; target; } from presets.linuxPortable, else null.
      zig ? null,
      # ndk: { clang; target; } from presets.android, else null.
      ndk ? null,
      # The kinds to choose from (`targets.<triple>.linkerKinds`).
      kinds ? builtinKinds,
    }:
    let
      all = kindsOf kinds;
      asked = "`linkerKind = \"${kind}\"`";
      k = all.${kind};
      why = k.incompatible {
        inherit
          triple
          traits
          lto
          staticNonPie
          zig
          ndk
          ;
      };
    in
    if kind == null then
      defaultKind {
        inherit
          triple
          traits
          lto
          rustc
          ;
      }
    else if !(all ? ${kind}) then
      throw "breakbulk.presetHelpers.chooseLinker: unknown linker kind `${kind}` for `${triple}`; known: ${lib.concatStringsSep ", " (lib.attrNames all)} (add one to `targets.${triple}.linkerKinds`)"
    else if !(k.on traits) then
      throw "breakbulk.presetHelpers.chooseLinker: ${asked} links for ${k.what} targets, not for `${triple}`"
    else if lto && !k.bitcode then
      throw "breakbulk.presetHelpers.chooseLinker: ${asked} cannot link for `${triple}` with `crossLanguageLto`, which needs a linker that reads LLVM bitcode (${
        lib.concatMapStringsSep ", " (n: "`${n}`") (
          lib.attrNames (lib.filterAttrs (_: k: k.bitcode && k.on traits) all)
        )
      })"
    else if why != null then
      throw "breakbulk.presetHelpers.chooseLinker: ${asked} cannot link for `${triple}`: ${why}"
    else
      kind;

  # What `linkerKind` needs to know about a Rust toolchain running on
  # `pkgs`' build platform: from its `facts` (toolchainFacts.of), or
  # those of `rustc`.
  rustcFacts =
    {
      pkgs,
      rustc ? null,
      facts ? toolchainFacts.of {
        pkgs = pkgs.buildPackages;
        inherit rustc;
      },
    }:
    {
      inherit (facts) version bundledLld llvmVersion;
      host = targetTraits.nativeTriple pkgs.buildPackages;
    };

  chooseLinker =
    {
      # The preset's package set; its buildPackages run the wrappers.
      pkgs,
      triple,
      # The target's traits (lib/target-traits.nix); default: built-in.
      traits ? targetTraits.resolve { inherit triple; },
      lto ? false,
      # The kind asked for (`targets.<triple>.linkerKind`); null: the default.
      kind ? null,
      # The kinds to choose from (`targets.<triple>.linkerKinds`).
      kinds ? builtinKinds,
      # The facts of the Rust toolchain that links
      # (lib/toolchain-facts.nix): its release and build decide the Linux
      # default, and its LLVM the lld kinds' lld.
      facts ? null,
      staticNonPie ? false,
      # The package set whose C toolchain drives the link (cc, lld, mold,
      # clang-lld, mingw-lld); default: pkgs.
      packageSet ? pkgs,
      # LLVM packages matching rustc (lld, clang-lld, lld-link, wasm-ld,
      # wasm-component-ld); default: the facts'.
      llvm ? if facts == null then null else facts.llvmPackages,
      # mingw-lld: the lld package; default: `llvm`'s.
      lld ? null,
      # zig: { cc = <zig cc wrapper>; target = "<arch>-linux-<abi>.<glibc>"; }.
      zig ? null,
      # ndk: { clang = <the NDK's clang>; target = "<ndkTriple><api>"; }.
      ndk ? null,
    }:
    let
      k = linkerKind {
        inherit
          triple
          traits
          lto
          kind
          kinds
          staticNonPie
          zig
          ndk
          ;
        rustc = if facts == null then null else rustcFacts { inherit pkgs facts; };
      };
    in
    (kindsOf kinds).${k}.build {
      inherit
        pkgs
        packageSet
        llvm
        lld
        zig
        ndk
        triple
        traits
        ;
    };
in
{
  inherit
    chooseLinker
    linkerKind
    builtinKinds
    linkerFeatures
    lldOf
    lldHas
    rustcFacts
    ccDriverLinker
    lldLinker
    ;
}
