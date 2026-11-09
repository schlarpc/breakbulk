# Outputs and entry points

## Entry point

```nix
repo = breakbulk.lib.mkRepository {
  inherit pkgs;
  root = ./.;                 # or a flake's self (turned into a path: lib.fileset takes only paths)
  modules = [ ./nix/rust.nix ];
};
```

`modules` may be left out: with no `workspaces` declared, a root that has a `Cargo.toml` is one workspace, `default`, at `"."` (`repo.workspaces.default.packages.<pkg>`); declaring any workspace turns that default off. The flake-parts module needs no `modules` either, so importing it is the whole configuration of a single-workspace repository.

Modules receive `pkgs`, `root` (the repository root as a path, for reading project files), `repo` (the result itself, for another workspace's product used as an input; laziness makes the cycle harmless) and `breakbulk` (the library: presets, stage helpers, `xwinSdk`). `specialArgs` passed to `mkRepository` add to these and win.


## Outputs

| Attribute | Contents |
| --- | --- |
| `repo.workspaces.<ws>.target.<triple>.packages.<pkg>` | The product after default stages; `.stages.<name>` for each intermediate; `.debug` where split |
| `repo.workspaces.<ws>.packages.<pkg>`, `.tests.<pkg>.<test>` | The same, for the workspace's default target (`defaultTarget`) |
| `repo.workspaces.<ws>.target.<triple>.variants.<v>.{packages,tests}` | The same, for another variant |
| `repo.workspaces.<ws>.target.<triple>.tests.<pkg>.<test>` | Test binaries, for VM and system tests |
| `repo.workspaces.<ws>.target.<triple>.testRuns.<pkg>.<test>` | Test-run derivations |
| `repo.workspaces.<ws>.target.<triple>.testApps.<pkg>.<test>` | Runnable apps: the test binary with its test-run environment, run outside the sandbox |
| `repo.workspaces.<ws>.target.<triple>.doctests.<pkg>` | Doctest derivations |
| `repo.workspaces.<ws>.target.<triple>.benches.<pkg>.<bench>` | Bench binaries from the bench variant |
| `repo.workspaces.<ws>.target.<triple>.docs` | The documentation product (not built yet, [#6](https://github.com/schlarpc/breakbulk/issues/6)) |
| `repo.checks` | All checks and test runs flattened, ready for `checks.<system>`: the default variant's products, checks, test runs and doctests as `<ws>/<triple>/<pkg>/…`; other variants' test runs and doctests as `<ws>/<triple>/variant-<v>/<pkg>/…`; check and clippy variants as `<ws>/<triple>/variant-<v>/check` |
| `repo.sources.<crate>` | Fetched crate sources by name (and `<name>@<version>`) |
| `repo.workspaces.<ws>.toolchain.{rustc,cargo,clippy,rustfmt}` | The workspace's resolved toolchain |
| `repo.workspaces.<ws>.target.<triple>.{spec,traits}` | The resolved target spec and the target's traits |
| `repo.workspaces.<ws>.devShell` | A shell matching the planner's Cargo invocation ([The Nix library](../explanation/internals/nix-library.md#dev-shell)) |
| `repo.workspaces.<ws>.plans.<triple>.<variant>.{build,test}` | `plan.json`, for debugging |
| `repo.explainSharing` | Given two plans and a package, the inputs that make its units differ |
| `repo.config`, `repo.options`, `repo.optionsDoc` | The evaluated modules, and their `nixosOptionsDoc` |
