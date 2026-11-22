# Target traits: every fact about a target platform that breakbulk decides
# something from, in one record, from one function ("Target traits" in
# docs/src/explanation/internals/toolchains.md). Other code never inspects a
# triple's spelling; it reads these fields.
#
#   targetTraits = breakbulk.targetTraits;
#   t = targetTraits.resolve { triple = "x86_64-pc-windows-msvc"; };
#   t.isMsvc  t.executableSuffix  t.dylibPathVar  …
#   targetTraits.resolve { triple = "my-board"; traits = { os = "none"; }; }
#
# `parse` reads a built-in Rust target name into rustc's own cfg values
# (`target_vendor`, `target_os`, `target_env`, `target_abi`,
# `target_family`), plus `arch`, the triple's first component (not
# `target_arch`: `i686` and `armv7` stay as spelled, because the tool names
# below need that spelling: nixpkgs' armv7l is not its arm). A test checks
# it against
# `rustc --print cfg --target <t>`, and the derived fields rustc's
# target specs also state against `--print file-names` and
# `--print all-target-specs-json`, for every built-in target
# (`target-traits-rustc` in tests/nix). It returns null for a name it does
# not know (a custom target, a `.json` target spec, a target outside the
# OS table below).
#
# `derive` computes the rest from those base fields; `resolve` merges a
# user's `traits` (`targets.<triple>.traits`, for a target breakbulk does
# not know, or to correct one) over the parse, derives, and lets the
# user's values win again, so a user can set a base field (`os`) and have
# everything follow, or set a derived field (`executableSuffix`) directly. For a
# name `parse` does not know and no user traits, every field is an error
# naming `targets.<triple>.traits`, raised only when something reads it,
# so a target whose traits nothing needs still works.
#
# Fields (all always present):
#
#   triple                 the target name
#   arch vendor os env abi families   as above (families: a list)
#   kernel                 the kernel the target's programs run on: "linux"
#                          (os linux or android), "darwin" (Apple), the os
#                          for other OSes with a kernel of their own
#                          (windows, freebsd, …), null where there is none
#                          to speak of (none, uefi, cuda, wasm, wasi)
#   isLinux                a Linux userland: os linux (glibc, musl, …);
#                          false for Android, whose userland (bionic, its
#                          own linker and loader) breakbulk has no preset
#                          for (issue #27)
#   isWindows isMsvc isMingw          os windows; env msvc; env gnu
#   isApple isWasm isWasi isBareMetal isUefi
#   linksComponents        the link writes a WebAssembly component, not a
#                          core module: WASI from preview 2 on
#                          (wasm32-wasip2, -wasip3), whose target specs
#                          name `wasm-component-ld` as the linker
#   objectFormat           "elf" | "pe" | "macho" | "wasm" | "xcoff" (AIX):
#                          rustc's target-spec `binary-format` ("wasm"
#                          for every wasm architecture)
#   executableSuffix       rustc's target-spec `exe_suffix`: "" | ".exe" |
#                          ".efi" | ".wasm" | ".js" | ".ptx" | ".elf" (avr)
#   sharedLibraryPrefix sharedLibrarySuffix   `dll_prefix`, `dll_suffix`
#                          (dylib and cdylib): "lib" ".so" | "" ".dll"
#                          (Windows, Cygwin) | "lib" ".dylib" | "" ".wasm" |
#                          "lib" ".a" (AIX)
#   staticLibraryPrefix staticLibrarySuffix   `staticlib_prefix`,
#                          `staticlib_suffix`: "lib" ".a" | "" ".lib" (msvc)
#   sharedLibraryDir       where `install` puts a shared library: "bin"
#                          (Windows, Cygwin: found beside the executable
#                          or on PATH) | "lib"
#                          The four file-name fields are what
#                          `rustc --print file-names --crate-type <t>`
#                          prints for the target (`target-traits-rustc`
#                          checks every built-in target).
#   debugArtifacts         the debuginfo files rustc's link writes beside a
#                          linked output, which `--print file-names` does
#                          not name: a list of
#                            { suffix; when; perObject ? false;
#                              directory ? false; }
#                          `when` is "always" (for every crate the linker
#                          produces, whatever -C debuginfo says: the
#                          `.pdb` of msvc and UEFI, which rustc links
#                          MSVC-style and always passes /DEBUG),
#                          "split-packed" or "split-unpacked" (with
#                          debuginfo on and that -C split-debuginfo).
#                          `perObject`: one per object file (`.dwo`), not
#                          per output; `directory`: a directory (`.dSYM`).
#                          `install` places side files by it. Whether a
#                          unit gets a `debug` output is not decided from
#                          it: the planner reads the same list from its
#                          rustc's target spec into the plan
#                          (`targetDebuginfo`), so a custom target needs
#                          no traits for it
#   dylibPathVar dylibPathSep         the variable a process of this
#                          platform finds shared libraries through, run
#                          natively (Cargo's `dylib_path_envvar`): PATH on
#                          Windows, DYLD_FALLBACK_LIBRARY_PATH on Apple,
#                          LD_LIBRARY_PATH elsewhere, null for wasm and
#                          bare metal. A runner may deliver it under
#                          another name (wine: WINEPATH), see
#                          `dylibPathOf` in lib/test-runs.nix
#   debugInfo              the default of `targets.<t>.debugInfo` (decision
#                          137): "split" (into a `debug` output) on a Linux
#                          ELF target and on Apple (the `.dSYM`), "keep"
#                          elsewhere (msvc's `.pdb` is separate already;
#                          wasm and others have no splitting stage)
#   nixpkgsSystem          the target's nixpkgs platform: a `pkgsCross`
#                          attribute name, or a `crossSystem` attribute set
#                          (`{ config = "<GNU triple>"; }`, the triple
#                          with nixpkgs' CPU name: riscv64gc as riscv64,
#                          armv7 as armv7l). `presetHelpers.targetPkgsFor`
#                          imports nixpkgs with it, and `nixpkgsPlatform`
#                          elaborates it
#   zigArch                the architecture of `zig cc -target` (i686 as
#                          x86, riscv64gc as riscv64, armv7 as arm)
#   qemuArch               qemu-user's program suffix (`qemu-<arch>`, as
#                          nixpkgs' `qemuArch`: i686 as i386, powerpc64le
#                          as ppc64le)
#   xwinArch               xwin's name for an msvc target's library
#                          directories (`sdk.libDirs.<arch>`: x86, x86_64,
#                          aarch, aarch64); null for other targets
{ lib }:
let
  inherit (lib)
    elem
    hasPrefix
    removePrefix
    splitString
    ;

  # Target OS names as Rust triples spell them, to rustc's `target_os`.
  osNames = {
    linux = "linux";
    windows = "windows";
    darwin = "macos";
    macos = "macos";
    ios = "ios";
    tvos = "tvos";
    watchos = "watchos";
    visionos = "visionos";
    freebsd = "freebsd";
    netbsd = "netbsd";
    openbsd = "openbsd";
    dragonfly = "dragonfly";
    illumos = "illumos";
    solaris = "solaris";
    fuchsia = "fuchsia";
    redox = "redox";
    haiku = "haiku";
    hurd = "hurd";
    aix = "aix";
    cygwin = "cygwin";
    emscripten = "emscripten";
    none = "none";
    uefi = "uefi";
    cuda = "cuda";
    wasip1 = "wasi";
    wasip2 = "wasi";
    wasip3 = "wasi";
  };

  # wasm32, wasm32v1, wasm64.
  wasmArch = arch: builtins.match "wasm(32|64).*" arch != null;

  # nixpkgs' platform for a Rust target, where a `pkgsCross` attribute
  # builds it: Hydra builds those (and caches them), and some carry more
  # than the GNU triple (CPU flags, the kernel config). The check
  # `target-traits` elaborates each and compares nixpkgs' `rust.rustcTarget`
  # with the key; nixpkgs cannot seed this table itself, because several
  # examples share a Rust target (mingw-msvcrt-x86_64 and mingw-ucrt-x86_64,
  # armv7l-hf-multiplatform and remarkable1).
  nixpkgsSystems = {
    "aarch64-unknown-linux-gnu" = "aarch64-multiplatform";
    "aarch64-unknown-linux-musl" = "aarch64-multiplatform-musl";
    "x86_64-unknown-linux-gnu" = "gnu64";
    "x86_64-unknown-linux-musl" = "musl64";
    "i686-unknown-linux-gnu" = "gnu32";
    "i686-unknown-linux-musl" = "musl32";
    "riscv64gc-unknown-linux-gnu" = "riscv64";
    "riscv64gc-unknown-linux-musl" = "riscv64-musl";
    "armv7-unknown-linux-gnueabihf" = "armv7l-hf-multiplatform";
    "arm-unknown-linux-gnueabihf" = "raspberryPi";
    "arm-unknown-linux-musleabihf" = "muslpi";
    "powerpc64le-unknown-linux-gnu" = "powernv";
    "powerpc64le-unknown-linux-musl" = "musl-power";
    # nixpkgs spells the ELF ABI (gnuabielfv1); Rust infers it.
    "powerpc64-unknown-linux-gnu" = "ppc64-elfv1";
    "powerpc64-unknown-linux-musl" = "ppc64-musl";
    "s390x-unknown-linux-gnu" = "s390x";
    "loongarch64-unknown-linux-gnu" = "loongarch64-linux";
    "wasm32-wasip1" = "wasi32";
    # mingw-w64 with gcc and msvcrt (Rust's own windows-gnu CRT).
    "x86_64-pc-windows-gnu" = "mingw-msvcrt-x86_64";
    "i686-pc-windows-gnu" = "mingw-msvcrt-i686";
    # LLVM mingw-w64 with ucrt.
    "aarch64-pc-windows-gnullvm" = "mingw-ucrt-aarch64";
    "x86_64-pc-windows-gnullvm" = "mingw-ucrt-x86_64-llvm";
  };

  # Rust architecture names a tool spells otherwise; any other name is
  # the tool's too. Prefix rules cover the CPU-level variants (armv7,
  # thumbv7neon, riscv64gc, i586).
  renameArch =
    rules: arch:
    let
      hit = lib.findFirst (r: builtins.match r.match arch != null) null rules;
    in
    if hit == null then arch else hit.name;
  # nixpkgs' CPU names (lib/systems/parse.nix `cpuTypes`).
  nixpkgsCpu = renameArch [
    {
      match = "riscv64.*";
      name = "riscv64";
    }
    {
      match = "riscv32.*";
      name = "riscv32";
    }
    {
      match = "armv7";
      name = "armv7l";
    }
  ];
  # zig's `-target` architectures (`zig targets`).
  zigCpu = renameArch [
    {
      match = "i[3-6]86";
      name = "x86";
    }
    {
      match = "armeb.*";
      name = "armeb";
    }
    {
      match = "arm.*";
      name = "arm";
    }
    {
      match = "thumb.*";
      name = "thumb";
    }
    {
      match = "riscv64.*";
      name = "riscv64";
    }
    {
      match = "riscv32.*";
      name = "riscv32";
    }
  ];
  # qemu-user's program suffixes (`qemu-<arch>`), as nixpkgs' `qemuArch`.
  qemuCpu = renameArch [
    {
      match = "i[3-6]86";
      name = "i386";
    }
    {
      match = "(arm|thumb).*";
      name = "arm";
    }
    {
      match = "riscv64.*";
      name = "riscv64";
    }
    {
      match = "riscv32.*";
      name = "riscv32";
    }
    {
      match = "powerpc64le";
      name = "ppc64le";
    }
    {
      match = "powerpc64";
      name = "ppc64";
    }
    {
      match = "powerpc";
      name = "ppc";
    }
  ];
  # xwin's library directories (lib/xwin-sdk.nix).
  xwinCpu = renameArch [
    {
      match = "i[3-6]86";
      name = "x86";
    }
    {
      match = "thumbv7a";
      name = "aarch";
    }
  ];

  # Second components that are not rustc's `target_vendor`.
  vendorAliases = {
    wali = "unknown";
    oe = "unknown";
  };

  # rustc's `target_family` values per `target_os` (wasm architectures add
  # "wasm").
  unixOses = [
    "linux"
    "android"
    "macos"
    "ios"
    "tvos"
    "watchos"
    "visionos"
    "freebsd"
    "netbsd"
    "openbsd"
    "dragonfly"
    "illumos"
    "solaris"
    "fuchsia"
    "redox"
    "haiku"
    "hurd"
    "aix"
    "cygwin"
    "emscripten"
  ];

  appleOses = [
    "macos"
    "ios"
    "tvos"
    "watchos"
    "visionos"
  ];

  # The env and abi of a triple's last component(s) (after the OS), or
  # null when it is not one of these forms.
  envAbi =
    rest:
    let
      after = p: removePrefix "_" (removePrefix p rest);
      # `gnuasan` and the like are sanitizer builds of plain `gnu`.
      libc = p: {
        env = p;
        abi =
          if
            elem (after p) [
              "asan"
              "msan"
              "tsan"
            ]
          then
            ""
          else
            after p;
      };
    in
    if rest == "" || rest == "elf" || rest == "none" || rest == "threads" then
      {
        env = "";
        abi = "";
      }
    else if hasPrefix "gnu" rest then
      libc "gnu"
    else if hasPrefix "musl" rest then
      libc "musl"
    else if hasPrefix "uclibc" rest then
      libc "uclibc"
    else if
      elem rest [
        "msvc"
        "ohos"
        "newlib"
      ]
    then
      {
        env = rest;
        abi = "";
      }
    else if
      elem rest [
        "sim"
        "macabi"
      ]
    then
      {
        env = rest;
        abi = rest;
      }
    else if
      elem rest [
        "eabi"
        "eabihf"
        "softfloat"
      ]
    then
      {
        env = "";
        abi = rest;
      }
    else
      null;

  # A built-in target name -> { triple; arch; vendor; os; env; abi;
  # families; }, or null.
  parse =
    triple:
    let
      parts = splitString "-" triple;
      n = builtins.length parts;
      at = i: builtins.elemAt parts i;
      arch = at 0;
      # `<arch>-<os>…` (thumbv7em-none-eabihf, wasm32-wasip2) or
      # `<arch>-<vendor>-<os>…`.
      osAt = if n > 1 && osNames ? ${at 1} then 1 else 2;
      osWord = if n > osAt then at osAt else null;
      restParts = lib.drop (osAt + 1) parts;
      # `<arch>-linux-android…`: Android spells its OS after `linux`.
      android = osWord == "linux" && restParts != [ ] && hasPrefix "android" (lib.head restParts);
      os =
        if android then
          "android"
        else if osWord == "unknown" && n == 3 then
          "unknown"
        else if osWord == null then
          null
        else
          osNames.${osWord} or null;
      vendor = if osAt == 1 then "unknown" else vendorAliases.${at 1} or (at 1);
      rest =
        if android then
          removePrefix "android" (lib.concatStringsSep "-" restParts)
        else
          lib.concatStringsSep "-" restParts;
      wasiEnv = lib.removePrefix "wasi" osWord;
      ea =
        if os == "wasi" then
          (
            if rest == "" || rest == "threads" then
              {
                env = wasiEnv;
                abi = "";
              }
            else
              null
          )
        else if os == "redox" && rest == "" then
          {
            env = "relibc";
            abi = "";
          }
        else
          envAbi rest;
      isWasm = wasmArch arch;
      # rustc's x86 iOS, tvOS and watchOS targets without `-sim` are
      # simulators all the same.
      sim =
        vendor == "apple"
        && elem os [
          "ios"
          "tvos"
          "watchos"
        ]
        && elem arch [
          "x86_64"
          "i386"
        ]
        && ea != null
        && ea.env == "";
      e =
        if sim then
          {
            env = "sim";
            abi = "sim";
          }
        else
          ea;
    in
    if n < 2 || os == null || e == null || (osAt == 2 && n < 3) then
      null
    else
      {
        inherit triple arch os;
        vendor = vendor;
        inherit (e) env;
        # uwp is spelled as a vendor and is rustc's abi.
        abi = if vendor == "uwp" then "uwp" else e.abi;
        families =
          lib.optional (elem os unixOses) "unix"
          ++ lib.optional (os == "windows") "windows"
          ++ lib.optional isWasm "wasm";
      };

  baseFields = [
    "triple"
    "arch"
    "vendor"
    "os"
    "env"
    "abi"
    "families"
  ];

  # Everything else, from the base fields.
  derive =
    b:
    let
      isWindows = b.os == "windows";
      isMsvc = isWindows && b.env == "msvc";
      isMingw = isWindows && b.env == "gnu";
      isApple = elem b.os appleOses;
      isWasm = wasmArch b.arch;
      isUefi = b.os == "uefi";
      # A Linux userland; Android has the Linux kernel, not this.
      isLinux = b.os == "linux";
      isCuda = b.os == "cuda";
      # Cygwin's programs are PE files named as on Windows.
      isCygwin = b.os == "cygwin";
      objectFormat =
        if isApple then
          "macho"
        else if isWindows || isUefi || isCygwin then
          "pe"
        else if isWasm then
          "wasm"
        else if b.os == "aix" then
          "xcoff"
        else
          "elf";
      # rustc's specs allow `-C split-debuginfo` other than off
      # (`supported-split-debuginfo`) on Linux-kernel userlands
      # (rustc_target spec/base/linux.rs), except the riscv ones, which
      # override it, and unikraft's and WALI's, whose bases are their own.
      splitsDebuginfo =
        (b.os == "linux" || b.os == "android")
        && !isWasm
        && !hasPrefix "riscv" b.arch
        && b.vendor != "unikraft";
    in
    b
    // {
      inherit
        isWindows
        isMsvc
        isMingw
        isApple
        isWasm
        isUefi
        isLinux
        objectFormat
        ;
      kernel =
        if b.os == "linux" || b.os == "android" then
          "linux"
        else if isApple then
          "darwin"
        else if
          isWasm
          || elem b.os [
            "none"
            "uefi"
            "unknown"
            "cuda"
          ]
        then
          null
        else
          b.os;
      isWasi = b.os == "wasi";
      linksComponents =
        isWasm
        && b.os == "wasi"
        && !elem b.env [
          ""
          "p1"
        ];
      isBareMetal = b.os == "none";
      # rustc's target specs: `exe_suffix`, `dll_prefix`/`dll_suffix`
      # (dylib and cdylib), `staticlib_prefix`/`staticlib_suffix`
      # (`target-traits-rustc` compares them with `--print file-names`).
      executableSuffix =
        if isWindows || isCygwin then
          ".exe"
        else if isUefi then
          ".efi"
        else if b.os == "emscripten" then
          ".js"
        else if isCuda then
          ".ptx"
        else if isWasm then
          ".wasm"
        else if b.arch == "avr" then
          ".elf"
        else
          "";
      sharedLibraryPrefix = if isWindows || isCygwin || isWasm || isCuda then "" else "lib";
      sharedLibrarySuffix =
        if isWindows || isCygwin then
          ".dll"
        else if isApple then
          ".dylib"
        else if isWasm then
          ".wasm"
        else if isCuda then
          ".ptx"
        else if b.os == "aix" then
          ".a"
        else
          ".so";
      staticLibraryPrefix = if isMsvc then "" else "lib";
      staticLibrarySuffix = if isMsvc then ".lib" else ".a";
      # Where an installed shared library goes: next to the executables
      # where the loader looks there (Windows and Cygwin search the
      # executable's directory and PATH, not lib/).
      sharedLibraryDir = if isWindows || isCygwin then "bin" else "lib";
      debugArtifacts =
        # The targets rustc links with an MSVC-style linker (its
        # `msvc`/`msvc-lld` flavor, `debuginfo-kind` pdb): Windows msvc and
        # UEFI, whose base spec builds on msvc's and links with rust-lld
        # as lld-link (rustc_target spec/base/uefi_msvc.rs).
        if isMsvc || isUefi then
          [
            {
              suffix = ".pdb";
              when = "always";
            }
          ]
        else if isApple then
          # From rustc's dsymutil run with split-debuginfo=packed.
          [
            {
              suffix = ".dSYM";
              when = "split-packed";
              directory = true;
            }
          ]
        else if splitsDebuginfo then
          [
            # packed: one per linked output (rustc runs thorin).
            {
              suffix = ".dwp";
              when = "split-packed";
            }
            # unpacked: one per object file, where rustc wrote it.
            {
              suffix = ".dwo";
              when = "split-unpacked";
              perObject = true;
            }
          ]
        else
          [ ];
      dylibPathVar =
        if isWindows then
          "PATH"
        else if isApple then
          "DYLD_FALLBACK_LIBRARY_PATH"
        else if isWasm || b.os == "none" || isUefi then
          null
        else
          "LD_LIBRARY_PATH";
      dylibPathSep = if isWindows then ";" else ":";
      # What a target's products do with debug info by
      # default (`targets.<t>.debugInfo` overrides it): split it off into
      # a `debug` output on a Linux ELF target and on Apple, where it is
      # the link's `.dSYM` already and the binary keeps only a debug map
      # naming build paths; elsewhere keep it in the file (msvc's PDB is
      # separate already; wasm and other targets have no splitting stage).
      debugInfo = if (isLinux && objectFormat == "elf") || isApple then "split" else "keep";
      # The target's name in the tools that spell it their own way.
      nixpkgsSystem =
        nixpkgsSystems.${b.triple} or {
          config = lib.concatStringsSep "-" (
            [ (nixpkgsCpu b.arch) ] ++ lib.drop 1 (splitString "-" b.triple)
          );
        };
      zigArch = zigCpu b.arch;
      qemuArch = qemuCpu b.arch;
      xwinArch = if isMsvc then xwinCpu b.arch else null;
    };

  fieldNames = lib.attrNames (derive {
    triple = "";
    arch = "";
    vendor = "";
    os = "";
    env = "";
    abi = "";
    families = [ ];
  });

  # The traits of `triple`: built-in ones (`parse`) with `traits` (the
  # user's, `targets.<triple>.traits`) merged over them.
  resolve =
    {
      triple,
      traits ? { },
    }:
    let
      parsed = parse triple;
      unknownMsg = "breakbulk: no built-in traits for the target `${triple}`; declare them with `targets.\"${triple}\".traits = { os = …; env = …; … }` (see https://schlarpc.github.io/breakbulk/explanation/internals/toolchains.html#target-traits)";
      unknown = lib.genAttrs fieldNames (f: throw "${unknownMsg} (needed: `${f}`)");
      base =
        (
          if parsed != null then
            parsed
          else
            {
              inherit triple;
              arch = lib.head (splitString "-" triple);
              vendor = "unknown";
              os = "unknown";
              env = "";
              abi = "";
              families = [ ];
            }
        )
        // lib.getAttrs (lib.intersectLists baseFields (lib.attrNames traits)) traits;
      # A misspelt or renamed field would otherwise be ignored silently.
      misnamed = lib.subtractLists fieldNames (lib.attrNames traits);
    in
    if misnamed != [ ] then
      throw "breakbulk: targets.\"${triple}\".traits: unknown trait(s) ${lib.concatStringsSep ", " misnamed}; known: ${lib.concatStringsSep ", " fieldNames}"
    else if parsed == null && traits == { } then
      unknown
    else
      derive base // traits;

  # nixpkgs' elaborated platform for a target's `nixpkgsSystem`. A
  # platform nixpkgs rejects fails here, naming the traits to set, rather
  # than inside nixpkgs' parser.
  #
  #   nixpkgsPlatform traits -> lib.systems.elaborate's result
  nixpkgsPlatform =
    traits:
    let
      s = traits.nixpkgsSystem;
      named = builtins.isString s;
      crossSystem = if named then lib.systems.examples.${s} or null else s;
      platform = lib.systems.elaborate crossSystem;
      shown =
        if named then
          "pkgsCross.${s}"
        else
          "crossSystem ${lib.generators.toPretty { multiline = false; } s}";
      fix = "set `targets.\"${traits.triple}\".traits.nixpkgsSystem` to a nixpkgs crossSystem (`{ config = \"<GNU triple>\"; … }`) or a `pkgsCross` attribute name, or give its preset a package set (`breakbulk.presets.<name> { packageSet = …; }`)";
    in
    if named && crossSystem == null then
      throw "breakbulk: the target `${traits.triple}` names ${shown}, which nixpkgs does not have; ${fix}"
    else if !(builtins.tryEval platform.system).success then
      throw "breakbulk: nixpkgs does not know the platform of the target `${traits.triple}` (${shown}; `lib.systems.elaborate` rejects it); ${fix}"
    else
      platform;

  # The Rust target of the machine `pkgs` builds for (the native triple of
  # a native package set).
  nativeTriple = pkgs: pkgs.stdenv.hostPlatform.rust.rustcTarget;

  # What rustc and Cargo get as `--target` for the target `name` whose
  # `rustcTarget` is given (`targets.<name>.rustcTarget`): `name` itself,
  # or a `.json` target spec named `<name>.json`. Cargo keys a `.json`
  # target by its file stem (`[target.<stem>]`, `CARGO_TARGET_<STEM>_*`,
  # its directory in the target directory, build scripts' `TARGET`) and
  # breakbulk by `name` (derivation names, `CC_<name>`), so the two must
  # agree. The spec is passed as a copy at `<store path>/<name>.json`, not
  # as the file: a file directly in the store has its hash in its stem.
  #
  #   rustcTargetArg { pkgs; name; rustcTarget; } -> { arg; storePath; }
  #   (storePath: the copy's directory, or null for a triple)
  rustcTargetArg =
    {
      pkgs,
      name,
      rustcTarget,
    }:
    let
      s = toString rustcTarget;
      base = baseNameOf s;
      hashed = builtins.match "[0-9a-df-np-sv-z]{32}-(.*)" base;
      file = if dirOf s == builtins.storeDir && hashed != null then lib.head hashed else base;
      stem = lib.removeSuffix ".json" file;
      copy = pkgs.runCommandLocal "${name}-target-spec" { } ''
        mkdir $out
        cp ${rustcTarget} $out/${lib.escapeShellArg "${name}.json"}
      '';
    in
    if !lib.hasSuffix ".json" s then
      if s == name then
        {
          arg = name;
          storePath = null;
        }
      else
        throw "breakbulk: targets.\"${name}\".rustcTarget is `${s}`, neither the target's name nor a `.json` target spec; for a triple rustc knows, name the target `${s}`"
    else if stem != name then
      throw "breakbulk: targets.\"${name}\".rustcTarget is the target spec `${file}`; Cargo names a `.json` target by its file stem, so name the target `${stem}` or the file `${name}.json`"
    else
      {
        arg = "${copy}/${name}.json";
        storePath = "${copy}";
      };

  # The name of the preset (`breakbulk.presets.<name>`) a target gets when
  # it sets none, or null. Only a preset that needs no arguments can be a
  # default: msvc needs SDK choices, so `-msvc` triples have none. The
  # native triple's follows the `pkgs` given to mkRepository, not the
  # machine evaluating: a glibc Linux package set gets "linux", a musl one
  # (`pkgs.pkgsMusl`, or nixpkgs on a musl system) "linuxStatic".
  #
  #   defaultPreset { pkgs; triple; traits ? <built-in>; } -> a name or null
  defaultPreset =
    {
      pkgs,
      triple,
      traits ? resolve { inherit triple; },
    }:
    let
      h = pkgs.stdenv.hostPlatform;
    in
    if triple == nativeTriple pkgs then
      (
        if !h.isLinux then
          null
        else if h.isMusl then
          "linuxStatic"
        else if h.isGnu then
          "linux"
        else
          null
      )
    else if traits.isUefi then
      "uefi"
    else
      null;

in
{
  inherit
    parse
    derive
    resolve
    nativeTriple
    rustcTargetArg
    defaultPreset
    fieldNames
    nixpkgsSystems
    nixpkgsPlatform
    ;
}
