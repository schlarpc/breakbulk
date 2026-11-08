# Target traits: every fact about a target platform that breakbulk decides
# something from, in one record, from one function ("Target traits" in
# docs/implementation.md). Other code never inspects a triple's spelling;
# it reads these fields.
#
#   targetTraits = breakbulk.targetTraits;
#   t = targetTraits.resolve { triple = "x86_64-pc-windows-msvc"; };
#   t.isMsvc  t.exeSuffix  t.dylibPathVar  …
#   targetTraits.resolve { triple = "my-board"; traits = { os = "none"; }; }
#
# `parse` reads a built-in Rust target name into rustc's own cfg values
# (`target_vendor`, `target_os`, `target_env`, `target_abi`,
# `target_family`), plus `arch`, the triple's first component (not
# `target_arch`: `i686` and `armv7` stay as spelled, because tool and SDK
# names use that spelling). A test checks it against
# `rustc --print cfg --target <t>` for every built-in target
# (`target-traits-rustc` in tests/nix). It returns null for a name it does
# not know (a custom target, a `.json` target spec, a target outside the
# OS table below).
#
# `derive` computes the rest from those base fields; `resolve` merges a
# user's `traits` (`targets.<triple>.traits`, for a target breakbulk does
# not know, or to correct one) over the parse, derives, and lets the
# user's values win again, so a user can set a base field (`os`) and have
# everything follow, or set a derived field (`exeSuffix`) directly. For a
# name `parse` does not know and no user traits, every field is an error
# naming `targets.<triple>.traits`, raised only when something reads it,
# so a target whose traits nothing needs still works.
#
# Fields (all always present):
#
#   triple                 the target name
#   arch vendor os env abi families   as above (families: a list)
#   isLinux                Linux kernel: os linux or android
#   isWindows isMsvc isMingw          os windows; env msvc; env gnu
#   isApple isWasm isWasi isBareMetal isUefi
#   objectFormat           "elf" | "pe" | "macho" | "wasm"
#   exeSuffix              "" | ".exe" | ".efi" | ".wasm" | ".js"
#   dylibPrefix dylibSuffix           "lib" ".so" | "" ".dll" | "lib" ".dylib" | "" ".wasm"
#   staticlibPrefix staticlibSuffix   "lib" ".a" | "" ".lib" (msvc)
#   debugSideFile          debuginfo kept beside a linked binary: "pdb"
#                          (msvc), "dwp" (ELF, with split-debuginfo),
#                          "dSYM" (Mach-O), or null
#   linkerWritesDebugFile  the linker writes `debugSideFile` for every
#                          linked crate, whatever -C debuginfo says (msvc:
#                          rustc always passes /DEBUG; decision 97)
#   dylibPathVar dylibPathSep         the variable a process of this
#                          platform finds shared libraries through, run
#                          natively (Cargo's `dylib_path_envvar`): PATH on
#                          Windows, DYLD_FALLBACK_LIBRARY_PATH on Apple,
#                          LD_LIBRARY_PATH elsewhere, null for wasm and
#                          bare metal. A runner may deliver it under
#                          another name (wine: WINEPATH), see
#                          `dylibPathOf` in lib/test-runs.nix
#   stagePreset            the default post-link stage chain for a target
#                          with no `stagePreset` (lib/stages.nix):
#                          "linuxGnu" (split debug info) on Linux, "msvc"
#                          (none) on msvc, null otherwise
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
      isLinux = b.os == "linux" || b.os == "android";
      objectFormat =
        if isApple then
          "macho"
        else if isWindows || isUefi then
          "pe"
        else if isWasm then
          "wasm"
        else
          "elf";
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
      isWasi = b.os == "wasi";
      isBareMetal = b.os == "none";
      exeSuffix =
        if isWindows then
          ".exe"
        else if isUefi then
          ".efi"
        else if b.os == "emscripten" then
          ".js"
        else if isWasm then
          ".wasm"
        else
          "";
      dylibPrefix = if isWindows || isWasm then "" else "lib";
      dylibSuffix =
        if isWindows then
          ".dll"
        else if isApple then
          ".dylib"
        else if isWasm then
          ".wasm"
        else
          ".so";
      staticlibPrefix = if isMsvc then "" else "lib";
      staticlibSuffix = if isMsvc then ".lib" else ".a";
      debugSideFile =
        if isMsvc then
          "pdb"
        else if objectFormat == "macho" then
          "dSYM"
        else if objectFormat == "elf" then
          "dwp"
        else
          null;
      linkerWritesDebugFile = isMsvc;
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
      stagePreset =
        if isLinux then
          "linuxGnu"
        else if isMsvc then
          "msvc"
        else
          null;
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
      unknownMsg = "breakbulk: no built-in traits for the target `${triple}`; declare them with `targets.\"${triple}\".traits = { os = …; env = …; … }` (see \"Target traits\" in docs/implementation.md)";
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
    in
    if parsed == null && traits == { } then unknown else derive base // traits;

  # The Rust target of the machine `pkgs` builds for (the native triple of
  # a native package set).
  nativeTriple = pkgs: pkgs.stdenv.hostPlatform.rust.rustcTarget;
in
{
  inherit
    parse
    derive
    resolve
    nativeTriple
    fieldNames
    ;

  # The part of the traits breakbulk's Rust programs read
  # (`toolchains.json`'s `targetTraits`, breakbulk-format `TargetTraits`).
  forRust = t: { inherit (t) linkerWritesDebugFile; };
}
