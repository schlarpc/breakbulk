# The objcopy for a platform's object files: one function, as the linker
# choice is (./linker.nix). Test runs strip with it (`test.stripForRun`).
#
#   chooseObjcopy { pkgs; traits; packageSet ? null; }
#     -> the path of an objcopy, or null
#
#   objectFormat (traits)  package set    objcopy
#   elf                    `packageSet`   its C compiler's binutils
#                                         (`stdenv.cc.bintools`, with the
#                                         target's prefix)
#   elf                    none           binutils-unwrapped-all-targets
#                                         from `pkgs`
#   pe, macho, others      -              null
#
# `pkgs` is the package set the stripping derivation builds with (the
# build machine's); `packageSet` the target's (`targets.<t>.packageSet`,
# or `pkgs` for the native triple).
#
# Not `llvm-objcopy` from the LLVM matching rustc: for the native target
# the stdenv's binutils is in every derivation already, and for a cross
# Linux target the cross binutils is what its C compiler wraps, while an
# LLVM is a large new input there, and dropping debug sections does not
# depend on the LLVM release. Without a package set (bare metal, a custom
# target) no binutils for the target's machine is at hand; the all-targets
# build reads every ELF machine and is much smaller than an LLVM.
#
# Not ELF: null, as the run's strip rewrites ELF files only.
{
  chooseObjcopy =
    {
      pkgs,
      traits,
      packageSet ? null,
    }:
    if traits.objectFormat != "elf" then
      null
    else if packageSet != null then
      let
        b = packageSet.stdenv.cc.bintools;
      in
      "${b}/bin/${b.targetPrefix}objcopy"
    else
      "${pkgs.binutils-unwrapped-all-targets}/bin/objcopy";
}
