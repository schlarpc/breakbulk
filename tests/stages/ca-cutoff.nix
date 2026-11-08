# Manual experiment: stages as content-addressed derivations, and early
# cutoff between them. Not a flake check, because it needs the
# `ca-derivations` experimental feature, which a stock daemon does not have.
# It runs without daemon support in a chroot store, substituting from the
# system store:
#
#   store=$TMPDIR/castore
#   nix build --impure --no-link --print-out-paths \
#     --extra-experimental-features ca-derivations \
#     --store $store --substituters 'daemon?trusted=true' \
#     --option build-dir $TMPDIR/builds \
#     -f tests/stages/ca-cutoff.nix --argstr salt a
#
# Then again with `--argstr salt b`. `salt` changes the `linked` derivation
# (input-addressed) without changing its bytes, so `linked` and `splitDebug`
# rebuild (splitDebug's resolved derivation has a new input path), splitDebug
# produces the same output path, and `install` is not rebuilt: the second
# run prints the same product path. Observed on Determinate Nix 3.22.2
# (Nix 2.35.2).
#
# `-gno-record-gcc-switches` matters: nixpkgs' stdenv passes
# `-frandom-seed=<output hash>`, and GCC records its switches in
# DW_AT_producer, so without it the link output's bytes (and its build ID)
# follow the derivation path.
#
# Without the feature, evaluation fails with "experimental Nix feature
# 'ca-derivations' is disabled"; with the feature on the client only, the
# daemon fails the build with the same message.
{
  salt ? "a",
}:
let
  flake = builtins.getFlake (toString ../..);
  pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
  S = flake.lib.stages;
  src = ./fixtures/hello-c;
  linked =
    pkgs.runCommandCC "hello-linked"
      {
        NIX_NO_SELF_RPATH = 1;
        inherit salt;
      }
      ''
        mkdir $out
        $CC -g -gno-record-gcc-switches -O0 -Wl,--build-id=sha1 ${src}/hello.c -o $out/hello
      '';
in
S.mkProduct {
  name = "hello";
  inherit linked pkgs;
  stages = S.chain [ "splitDebug" ];
  sourcePaths = [ src ];
  ca = true;
}
