# Wrap or package a binary

A wrapper script, a launcher, a `.desktop` file or an archive belongs
after `install`, where the product already has its final layout
(`bin/`, `lib/`, and `pkg/` after `bindgen`). This page shows how to
add such a stage.

## Wrap a binary

Add a stage with `after = "install"`:

```nix
modules = [{
  packages.app.stages.wrap = {
    after = "install";
    run = { input, pkgs, ... }:
      pkgs.runCommand "app-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
        cp -R ${input} $out
        chmod -R u+w $out
        wrapProgram $out/bin/app --prefix PATH : ${pkgs.git}/bin
      '';
  };
}];
```

`input` is the installed layout, so the binary is at `bin/app`. The
wrapper names `$out/bin/.app-wrapped`, the stage's own output. The
product's runtime closure holds only that output, not the earlier
stages.

Do not wrap before `install`. `install` copies the wrapper into its own
output, but the wrapper still runs the binary of the earlier stage, so
the product depends on both copies.

## Package the installed tree

Any number of stages can follow `install`. Order them with `after`, as
any other stages:

```nix
packages.app.stages = {
  wrap = { after = "install"; run = …; };
  zip  = { after = "wrap"; run = breakbulk.stageHelpers.deterministicZip; };
};
```

The product is the last stage, here `zip`. Every earlier stage stays
available as `.stages.<name>`, for example `.stages.install`.

## Which side of `install`

| Stage | Before `install` | After `install` |
| --- | --- | --- |
| Sees | the flat link output: `app`, `app.exe`, `libfoo.so` | the installed layout: `bin/app`, `lib/libfoo.so`, `pkg/` after `bindgen` |
| Use for | changing the binary: `splitDebug`, `strip`, `patchelfRpath`, `bindgen`, `wasmOpt` | wrappers, launchers, `.desktop` files, signing, archives, images |
| Default | yes: a stage that names neither runs before `install` | `after = "install"`, or after a stage that is |

The stage helpers expect the flat link output. Run them before `install`.

A check sees the bytes of the stage it is on. `checks.<name>.on =
"install"` sees the installed layout without your wrapper.

## Debug information

A stage after `install` with no `debug` output keeps the product's
`debug` output: `splitDebug`'s on Linux, `install`'s PDBs on Windows
(MSVC). Wrapping, `patchelf` and signing keep the GNU build ID and the
debuglink, and Authenticode signing keeps the PDB reference.

A stage that moves binaries, for example into `opt/app/`, must also move
their Windows PDBs: a debugger looks for the PDB next to the `.exe`. Give
that stage its own `debug` output with the PDBs at the new place
(`$debug/opt/app/app.pdb` for `$out/opt/app/app.exe`). The product's
`debug` output is that of the last stage that has one.

More on stages: [Products, stages and tests](../explanation/products.md).
