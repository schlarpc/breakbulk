# Summary

[Introduction](index.md)

# Tutorials

- [Your first project](tutorials/first-project.md)

# How-to guides

- [Add a native library](how-to/native-library.md)
- [Build for another target](how-to/targets.md)
- [Rebuild less when unrelated files change](how-to/filter-source.md)
- [Format with treefmt](how-to/treefmt.md)
- [Use a binary cache](how-to/binary-cache.md)
- [Use a flake with several systems](how-to/multi-system.md)

# Reference

- [Module options](reference/options.md)
  - [Repository-wide](reference/options/repository.md)
  - [Workspaces](reference/options/workspaces.md)
  - [Targets](reference/options/targets.md)
  - [Packages](reference/options/packages.md)
- [Outputs and entry points](reference/outputs.md)
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
