# zig (M7): Linux gnu programs linked against an old glibc (default 2.17,
# the oldest Rust's std supports on x86_64) with `zig cc -target
# <arch>-linux-gnu.<glibc>` as the target units' linker and C compiler.
#
#   targets.x86_64-unknown-linux-gnu.preset = breakbulk.presets.zig { glibc = "2.17"; };
#
# A same-triple preset: the target is usually the host triple, which the
# planner passes as `--target`, so the zig linker and rustflags reach target
# units only and host units (build scripts, proc macros) keep the host
# linker through the planner's linker rewrite.
#
# zig builds glibc's stubs, crt objects, libunwind and compiler-rt into its
# global cache on first use (about 10 s). In a sandbox that cache starts
# empty in every unit, so `cache` is a derivation that warms it once, and
# the wrapper copies it into the unit's $TMPDIR on first use (about 60 MB,
# well under 0.1 s). zig cannot use the store copy in place: it opens cache
# manifests for writing even on a hit ("manifest_create AccessDenied" with
# a read-only cache, zig 0.17.0); a copy at another path is a full hit.
# breakbulk-unit has no zig special case: the wrapper does it all.
{
  lib,
  hostSpec,
  driverWrapper,
}:
{
  pkgs,
  triple ? pkgs.stdenv.hostPlatform.rust.rustcTarget,
  glibc ? "2.17",
  zig ? pkgs.buildPackages.zig,
  # Extra `zig cc` invocations' flags to warm the cache with, e.g.
  # [ "-lc++" ] for C++ code.
  warmFlags ? [ ],
  ...
}:
let
  inherit (lib) mkDefault;
  bp = pkgs.buildPackages;
  m = builtins.match "([a-z0-9_]+)-unknown-linux-gnu" triple;
  rustArch =
    if m == null then
      throw "breakbulk.presets.zig: `${triple}` is not a *-unknown-linux-gnu triple"
    else
      lib.head m;
  zigArch = { riscv64gc = "riscv64"; }.${rustArch} or rustArch;
  zigTarget = "${zigArch}-linux-gnu.${glibc}";

  # The warmed global cache: an executable and a shared library linked with
  # the libraries rustc's linux-gnu spec passes.
  cache =
    bp.runCommand "zig-cache-${zigTarget}"
      {
        nativeBuildInputs = [ zig ];
      }
      ''
        export ZIG_GLOBAL_CACHE_DIR=$out ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
        printf 'int main(void) { return 0; }\n' > main.c
        libs="-lgcc_s -lutil -lrt -lpthread -lm -ldl -lc"
        zig cc -target ${zigTarget} main.c -o main $libs
        zig cc -target ${zigTarget} -shared -fPIC main.c -o libmain.so $libs
        zig cc -target ${zigTarget} -O2 -c main.c -o main.o
        ${lib.concatMapStringsSep "\n" (
          f: "zig cc -target ${zigTarget} main.c -o extra ${f} $libs"
        ) warmFlags}
        rm -rf $out/tmp
      '';

  # `zig <mode>` with the warmed cache copied into $TMPDIR once per unit
  # (copied aside, then renamed, so parallel cc jobs do not race).
  zigTool =
    name: mode:
    "${bp.writeShellScriptBin name ''
      dir="''${TMPDIR:-/tmp}/breakbulk-zig"
      if [[ ! -d $dir/global ]]; then
        mkdir -p "$dir"
        tmp=$(mktemp -d "$dir/copy.XXXXXX")
        cp -r ${cache} "$tmp/global"
        chmod -R u+w "$tmp/global"
        mv -T "$tmp/global" "$dir/global" 2>/dev/null || rm -rf "$tmp/global"
        rmdir "$tmp"
      fi
      export ZIG_GLOBAL_CACHE_DIR="$dir/global" ZIG_LOCAL_CACHE_DIR="$dir/local"
      # The cc crate passes `--target=<Rust triple>` (zig cannot parse
      # it, and it would override -target); the target is fixed here.
      args=()
      for a in "$@"; do
        [[ $a == --target=* ]] || args+=("$a")
      done
      exec ${zig}/bin/zig ${mode} "''${args[@]}"
    ''}/bin/${name}";

  zigCc = zigTool "zig-cc-${zigTarget}" "cc -target ${zigTarget}";
  zigCxx = zigTool "zig-cxx-${zigTarget}" "c++ -target ${zigTarget}";
  zigAr = zigTool "zig-ar" "ar";
in
{
  packageSet = mkDefault pkgs;
  # driverWrapper drops the `-fuse-ld=lld -B…/gcc-ld` rustc adds on
  # x86_64 (rustc's self-contained rust-lld); zig links with its own lld.
  linker = mkDefault (driverWrapper pkgs "zig-cc-link-${zigTarget}" zigCc "");
  cc = mkDefault zigCc;
  cxx = mkDefault zigCxx;
  ar = mkDefault zigAr;
  env = { };
  # zig links the FHS loader path (/lib64/ld-linux-x86-64.so.2), as a
  # program for other distributions should; the Nix sandbox has none, so
  # tests run through the build machine's glibc loader, which also finds
  # its own libc.so.6 (newer than `glibc`, as on a real target system).
  runner = mkDefault (
    if
      pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform
      && triple == pkgs.stdenv.hostPlatform.rust.rustcTarget
    then
      bp.writeShellScript "breakbulk-runner-ld-so" ''
        exec ${pkgs.stdenv.cc.bintools.dynamicLinker} "$@"
      ''
    else
      null
  );
  testSystem = mkDefault null;
  host = hostSpec pkgs;
  stagePreset = mkDefault "linuxGnu";
}
