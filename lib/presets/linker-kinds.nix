# The linker kinds of ./linker.nix, with what each links for, apart from
# the wrappers, so `targets.<triple>.linkerKind` (lib/modules/target-spec.nix)
# can name them without the presets.
#
#   kinds.<kind>   { on = traits: bool; what; bitcode ? false; choosable ? true; }
#   names          the kinds `targets.<triple>.linkerKind` may name
#
# `on`: the targets it links for (from lib/target-traits.nix's traits;
# `what` describes them); `bitcode`: it reads rustc's LLVM bitcode, for
# `-C linker-plugin-lto`; `choosable`: `linkerKind` may name it (zig comes
# with linuxPortable's backend, which also sets the C compiler and glibc).
{ lib }:
let
  kinds = {
    cc = {
      on = t: t.isLinux;
      what = "Linux";
    };
    lld = {
      on = t: t.isLinux;
      what = "Linux";
    };
    mold = {
      on = t: t.isLinux;
      what = "Linux";
    };
    clang-lld = {
      on = t: t.isLinux;
      what = "Linux";
      bitcode = true;
    };
    zig = {
      on = t: t.isLinux && t.env == "gnu";
      what = "Linux -gnu";
      choosable = false;
    };
    lld-link = {
      on = t: t.isMsvc;
      what = "Windows -msvc";
      bitcode = true;
    };
    wasm-ld = {
      on = t: t.isWasm && !(t.isWasi && t.env == "p2");
      what = "wasm (not wasm32-wasip2)";
      bitcode = true;
    };
    wasm-component-ld = {
      on = t: t.isWasm && t.isWasi && t.env == "p2";
      what = "wasm32-wasip2";
      bitcode = true;
    };
    mingw-lld = {
      on = t: t.isMingw;
      what = "Windows -gnu and -gnullvm";
    };
  };
in
{
  inherit kinds;
  names = lib.attrNames (lib.filterAttrs (_: k: k.choosable or true) kinds);
}
