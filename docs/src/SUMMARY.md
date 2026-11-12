# Summary

[Introduction](index.md)

# Tutorials

- [Your first project](tutorials/first-project.md)

# How-to guides

- [Port a crane flake](how-to/port-from-crane.md)
- [Add a native library](how-to/native-library.md)
- [A build script runs Cargo](how-to/nested-cargo.md)
- [Build for another target](how-to/targets.md)
- [Wrap or package a binary](how-to/wrap-package.md)
- [Rebuild less when unrelated files change](how-to/filter-source.md)
- [Run snapshot tests](how-to/snapshot-tests.md)
- [Format with treefmt](how-to/treefmt.md)
- [Enter the dev shell with direnv](how-to/direnv.md)
- [Use a binary cache](how-to/binary-cache.md)
- [Use a flake with several systems](how-to/multi-system.md)
- [Run the checks in CI](how-to/ci.md)

# Reference

- [Module options](reference/options.md)
  - [Repository-wide](reference/options/repository.md)
  - [Workspaces](reference/options/workspaces.md)
  - [Targets](reference/options/targets.md)
  - [Packages](reference/options/packages.md)
- [Outputs and entry points](reference/outputs.md)
- [Stage and check functions](reference/stage-functions.md)
- [Stage helpers](reference/stage-helpers.md)
- [Presets](reference/presets.md)
- [Cargo and rustc assumptions](reference/assumptions.md)
- [Plan format](reference/plan-format.md)
- [Sentinel directives](reference/sentinels.md)
- [The unit builder](reference/unit-builder.md)

# Explanation

- [Why breakbulk](explanation/why.md)
- [How a build works](explanation/architecture.md)
- [The configuration model](explanation/configuration.md)
- [Products, stages and tests](explanation/products.md)
- [Targets and toolchains](explanation/targets.md)
- [Caching and early cutoff](explanation/caching.md)
- [Trade-offs and risks](explanation/trade-offs.md)
- [Patterns and prior art](explanation/prior-art.md)
- [Internals](explanation/internals/components.md)
  - [The traced planner](explanation/internals/planner.md)
  - [Instantiation](explanation/internals/instantiation.md)
  - [Environment capture](explanation/internals/env-capture.md)
  - [Fetching and source views](explanation/internals/sources.md)
  - [The Nix library](explanation/internals/nix-library.md)
  - [Target traits and presets](explanation/internals/toolchains.md)
  - [Products, stages and tests](explanation/internals/products.md)
  - [How breakbulk is tested](explanation/internals/testing.md)
