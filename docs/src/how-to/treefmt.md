# Format with treefmt

[treefmt-nix](https://github.com/numtide/treefmt-nix) runs every
formatter in the repository with `nix fmt`, and checks formatting in
`nix flake check`. breakbulk does not set the flake's `formatter`, so the
two work together.

## Set it up

With flake-parts, import both modules and give treefmt the workspace's
rustfmt:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    breakbulk.url = "github:schlarpc/breakbulk";
  };

  outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
    imports = [
      inputs.breakbulk.lib.flakeModule
      inputs.treefmt-nix.flakeModule
    ];
    systems = [ "x86_64-linux" ];
    perSystem = { config, ... }: {
      treefmt.programs.rustfmt = {
        enable = true;
        package = config.breakbulk.repo.workspaces.default.toolchain.rustfmt;
        edition = "2024";  # your crates' edition; see below
      };
      treefmt.programs.nixfmt.enable = true;
    };
  };
}
```

[`toolchain.rustfmt`](../reference/options/workspaces.md#workspacesnametoolchainrustfmt) is nixpkgs' rustfmt when the workspace uses nixpkgs'
rustc, and otherwise the toolchain's own, so formatting matches `cargo fmt`
in the dev shell.

Use treefmt's check instead of breakbulk's [`workspaces.<ws>.fmt.enable`](../reference/options/workspaces.md#workspacesnamefmtenable);
with both, the same files are checked twice.

## Match the edition

treefmt runs `rustfmt --edition <edition>` on each file, with
`programs.rustfmt.edition` (default `"2024"`). `cargo fmt` takes each
crate's edition from its `Cargo.toml`. The edition sets rustfmt's style
edition, so a 2021 crate gets 2024 style from treefmt and 2021 style from
`cargo fmt`, and the two disagree. Fix it in one of two ways:

- set `programs.rustfmt.edition` to your crates' edition, or
- pin the style in `rustfmt.toml`: `style_edition = "2024"`.
