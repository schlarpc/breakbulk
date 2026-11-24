# `nix flake check` build times per check

How this was measured:
- `tests/profile/run.sh` at b3515781 on 2026-11-24.
- Machine: Ryzen 7 5800X (8 cores / 16 threads), quiet, Nix `max-jobs = auto`.
- Scenario: one comment line added to `crates/breakbulk-unit/src/main.rs`. That rebuilds breakbulk's programs and everything built with them: every unit, product and test run of every check. This is the common worst case when working on breakbulk.
- Toolchains, SDKs and nixpkgs builds were already in the store. A first run after a nixpkgs or rust-overlay bump also builds or downloads those, and was not measured.

With nothing to rebuild, `nix flake check --no-eval-cache` takes 12.5 s (evaluation only).

To regenerate: make the same edit, run `tests/profile/run.sh <dir>`, then revert the edit.

How to read the table:
- **Total** is every build in the check's `.drv` closure that this run made. A build that several checks share counts in each.
- **Exclusive** counts only the builds that no other check needs, which is what dropping that check alone would save.
- Times are build minutes, not wall time: about 16 builds run in parallel.

Wall time 8.3 min; 4167 builds, 68.4 build-min; substitutions 0.0 min.

| Check | Total (min) | Exclusive (min) | Builds | Longest build |
|---|---|---|---|---|
| `differential` | 6.4 | 6.1 | 34 | breakbulk-plan-0.1.0.drv (0.4) |
| `self-host` | 3.1 | 1.7 | 178 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-tools-narrow` | 2.4 | 0.0 | 7 | breakbulk-drv-0.1.0.drv (0.7) |
| `build-std` | 2.4 | 2.2 | 20 | core-0.0.0-lib.drv (1.0) |
| `android-aarch64` | 2.3 | 0.9 | 135 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-source-overlay` | 2.2 | 0.8 | 93 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-sys-native` | 2.1 | 0.4 | 66 | breakbulk-plan-0.1.0.drv (0.4) |
| `products-benches` | 2.0 | 1.7 | 76 | main-x86_64-unknown-linux-gnu-bench-bench-bencher-bench-crit-run.drv (0.4) |
| `test-runs-test-control` | 1.9 | 1.2 | 35 | test-control-ctl-lib-ctl-run.drv (1.0) |
| `build-std-deps` | 1.8 | 1.6 | 38 | core-0.0.0-lib.drv (1.0) |
| `repository-roots-override` | 1.7 | 0.4 | 31 | breakbulk-doctest-0.1.0.drv (0.4) |
| `wasm-web-test-firefox` | 1.5 | 0.1 | 76 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasm-web-test-chromium` | 1.5 | 0.1 | 76 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasm-web-test` | 1.5 | 0.0 | 76 | breakbulk-unit-0.1.0.drv (0.2) |
| `msvc-x86_64-pdb` | 1.4 | 0.4 | 47 | msvc-x86_64-pdb.drv (0.3) |
| `msvc-x86_64-run` | 1.4 | 0.5 | 45 | msvc-x86_64-run.drv (0.3) |
| `differential-1_95` | 1.3 | 1.0 | 8 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-c-seed` | 1.3 | 0.1 | 48 | breakbulk-unit-0.1.0.drv (0.2) |
| `differential-1_97` | 1.3 | 0.9 | 8 | breakbulk-plan-0.1.0.drv (0.4) |
| `test-runs-test-control-include-ignored` | 1.3 | 1.0 | 15 | test-control-ctl-lib-ctl-run.drv (1.0) |
| `android-symbols` | 1.2 | 0.0 | 66 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-feature-unification` | 1.2 | 0.2 | 27 | breakbulk-doctest-0.1.0.drv (0.4) |
| `sys-native-aarch64` | 1.2 | 1.0 | 65 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-embed` | 1.1 | 0.2 | 25 | breakbulk-plan-0.1.0.drv (0.4) |
| `repository-view-hints` | 1.1 | 0.5 | 40 | breakbulk-doctest-0.1.0.drv (0.4) |
| `msvc-x86_64-test` | 1.1 | 0.9 | 44 | breakbulk-unit-0.1.0.drv (0.2) |
| `differential-nightly` | 1.1 | 0.8 | 8 | breakbulk-plan-0.1.0.drv (0.4) |
| `msvc-aarch64-build` | 1.1 | 0.2 | 45 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasm-host-inputs` | 1.1 | 0.4 | 49 | breakbulk-unit-0.1.0.drv (0.2) |
| `msvc-x86_64-relink` | 1.1 | 0.0 | 41 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-wasm-embed` | 1.1 | 0.2 | 22 | breakbulk-plan-0.1.0.drv (0.4) |
| `wasm-web-bindgen` | 1.0 | 0.3 | 49 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-curated-keeps` | 1.0 | 0.7 | 52 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-directives-nightly` | 1.0 | 0.3 | 38 | breakbulk-plan-0.1.0.drv (0.4) |
| `repository-own-view` | 0.9 | 0.3 | 43 | breakbulk-doctest-0.1.0.drv (0.4) |
| `test-runs-doctest-settings` | 0.9 | 0.3 | 25 | breakbulk-doctest-0.1.0.drv (0.4) |
| `products-docs` | 0.9 | 0.3 | 21 | breakbulk-docs-0.1.0.drv (0.4) |
| `products-trim-paths` | 0.9 | 0.4 | 34 | breakbulk-plan-0.1.0.drv (0.4) |
| `native-link-runs-lld` | 0.9 | 0.3 | 24 | breakbulk-doctest-0.1.0.drv (0.4) |
| `native-link-runs` | 0.9 | 0.3 | 24 | breakbulk-doctest-0.1.0.drv (0.4) |
| `cross-doctests-aarch64` | 0.9 | 0.3 | 25 | breakbulk-doctest-0.1.0.drv (0.4) |
| `loose-ends-devshell-env` | 0.9 | 0.5 | 6 | closure-info.drv (0.5) |
| `test-runs-post-run` | 0.9 | 0.1 | 28 | breakbulk-doctest-0.1.0.drv (0.4) |
| `plan-build-dep-leak` | 0.8 | 0.3 | 19 | breakbulk-plan-0.1.0.drv (0.4) |
| `test-runs-test-closure` | 0.8 | 0.2 | 18 | breakbulk-doctest-0.1.0.drv (0.4) |
| `test-runs-doctests` | 0.8 | 0.2 | 17 | breakbulk-doctest-0.1.0.drv (0.4) |
| `plan-dev-dep-features` | 0.8 | 0.3 | 26 | breakbulk-plan-0.1.0.drv (0.4) |
| `test-runs-home` | 0.8 | 0.2 | 16 | breakbulk-doctest-0.1.0.drv (0.4) |
| `test-runs-doctest-false` | 0.8 | 0.2 | 17 | breakbulk-doctest-0.1.0.drv (0.4) |
| `plan-crate-types` | 0.8 | 0.2 | 16 | breakbulk-plan-0.1.0.drv (0.4) |
| `build-std-tests` | 0.8 | 0.0 | 7 | breakbulk-plan-0.1.0.drv (0.4) |
| `repository-snapshots` | 0.7 | 0.5 | 38 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-config-env` | 0.7 | 0.1 | 15 | breakbulk-doctest-0.1.0.drv (0.4) |
| `test-runs-runner` | 0.7 | 0.0 | 13 | breakbulk-doctest-0.1.0.drv (0.4) |
| `products-trim-paths-cc` | 0.7 | 0.2 | 17 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-sys-native-golden-nightly-test` | 0.7 | 0.4 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-walking-skeleton-nightly` | 0.7 | 0.1 | 18 | breakbulk-plan-0.1.0.drv (0.4) |
| `test-runs-test-threads` | 0.7 | 0.5 | 69 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-ui-dist` | 0.7 | 0.1 | 38 | breakbulk-unit-0.1.0.drv (0.2) |
| `darwin-aarch64` | 0.7 | 0.5 | 37 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-test-scope` | 0.7 | 0.1 | 11 | breakbulk-doctest-0.1.0.drv (0.4) |
| `plan-sys-native-golden-1_95-test` | 0.7 | 0.3 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `breakbulk-drv` | 0.7 | 0.0 | 1 | breakbulk-drv-0.1.0.drv (0.7) |
| `plan-sys-native-golden-1_95` | 0.7 | 0.3 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-rlib-example` | 0.7 | 0.1 | 10 | breakbulk-plan-0.1.0.drv (0.4) |
| `linux-portable-native-glibc` | 0.6 | 0.0 | 26 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants` | 0.6 | 0.3 | 51 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-native-no-store-paths` | 0.6 | 0.0 | 26 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-native-libraries` | 0.6 | 0.0 | 26 | breakbulk-unit-0.1.0.drv (0.2) |
| `git-multi-workspace-build` | 0.6 | 0.1 | 13 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-sys-native-golden-1_97-test` | 0.6 | 0.3 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-directives` | 0.6 | 0.1 | 41 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-port-from-crane` | 0.6 | 0.4 | 42 | breakbulk-unit-0.1.0.drv (0.2) |
| `windows-gnullvm-test` | 0.6 | 0.4 | 10 | main-x86_64-pc-windows-gnullvm-default-gnu-smoke-bin-gnu-smoke-run.drv (0.3) |
| `windows-gnullvm-run` | 0.6 | 0.3 | 11 | windows-gnullvm-run.drv (0.3) |
| `windows-gnu-run` | 0.6 | 0.3 | 11 | windows-gnu-run.drv (0.3) |
| `plan-sys-native-golden-1_97` | 0.6 | 0.2 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-inherited-dylib-path` | 0.6 | 0.0 | 36 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-sys-native-golden-nightly` | 0.6 | 0.2 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `differential-errors-1_95` | 0.5 | 0.4 | 24 | breakbulk-unit-0.1.0.drv (0.2) |
| `windows-gnu-test` | 0.5 | 0.3 | 10 | main-x86_64-pc-windows-gnu-default-gnu-smoke-bin-gnu-smoke-run.drv (0.3) |
| `riscv64-run` | 0.5 | 0.4 | 26 | breakbulk-unit-0.1.0.drv (0.2) |
| `differential-errors` | 0.5 | 0.3 | 24 | breakbulk-unit-0.1.0.drv (0.2) |
| `differential-errors-nightly` | 0.5 | 0.3 | 24 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-predict-sources` | 0.5 | 0.3 | 28 | breakbulk-unit-0.1.0.drv (0.2) |
| `git-revisions-sharing` | 0.5 | 0.3 | 39 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-declared-paths` | 0.5 | 0.3 | 38 | breakbulk-unit-0.1.0.drv (0.2) |
| `differential-errors-1_97` | 0.5 | 0.3 | 24 | breakbulk-unit-0.1.0.drv (0.2) |
| `riscv64-test-lib` | 0.5 | 0.3 | 22 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-multi-ws-sharing` | 0.5 | 0.2 | 29 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-nextest` | 0.5 | 0.3 | 24 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-cargo-config` | 0.5 | 0.3 | 34 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-crate-sources` | 0.5 | 0.3 | 10 | crate-sources.drv (0.2) |
| `plan-directives-golden` | 0.5 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `test-runs-test-wrapper` | 0.4 | 0.3 | 26 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-build-script-files` | 0.4 | 0.3 | 30 | breakbulk-unit-0.1.0.drv (0.2) |
| `windows-gnullvm-aarch64-build` | 0.4 | 0.2 | 20 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-directives-golden-test` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-directives-golden-nightly-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-directives-golden-1_95` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `cross-lto` | 0.4 | 0.1 | 22 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-prefer-dynamic` | 0.4 | 0.2 | 27 | breakbulk-unit-0.1.0.drv (0.2) |
| `cross-lto-lld` | 0.4 | 0.1 | 22 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-clippy-toolchain` | 0.4 | 0.1 | 5 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-directives-golden-1_95-test` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `msvc-post-link` | 0.4 | 0.2 | 14 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-directives-golden-1_97` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-dev-dep-features-golden-1_97-test` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-walking-skeleton-golden-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-directives-golden-nightly` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-directives-golden-1_97-test` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-dev-dep-features-golden-1_95-test` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-dev-dep-features-golden-1_95` | 0.4 | 0.1 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-dev-dep-features-golden-nightly-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `linux-portable-armv7` | 0.4 | 0.2 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-devshell` | 0.4 | 0.0 | 5 | breakbulk-plan-0.1.0.drv (0.4) |
| `products-variants-clippy-host` | 0.4 | 0.2 | 25 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-build-dep-leak-golden-1_97-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-build-dep-leak-golden-1_95-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `windows-dll-needs-dll` | 0.4 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-nested-cargo` | 0.4 | 0.2 | 19 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-same-workspace-products` | 0.4 | 0.2 | 23 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-walking-skeleton-golden` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `loose-ends-devshell-trim-paths` | 0.4 | 0.0 | 5 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-dev-dep-features-golden-1_97` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `repository-stdenv-override` | 0.4 | 0.2 | 16 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-dev-dep-features-golden-nightly` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-walking-skeleton-golden-1_95-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-walking-skeleton-golden-nightly` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `repository-required-features` | 0.4 | 0.2 | 26 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-walking-skeleton-golden-1_97-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-build-dep-leak-golden-1_97` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-forced-target` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-build-dep-leak-golden-nightly` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-build-dep-leak-golden-nightly-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-build-dep-leak-golden-1_95` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-crate-types-golden-1_95` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-walking-skeleton-golden-nightly-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-crate-types-golden-nightly` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-walking-skeleton-golden-1_97` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `git-multi-workspace-golden-1_95` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `git-multi-workspace-golden` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `products-variants-coverage` | 0.4 | 0.2 | 20 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-devshell` | 0.4 | 0.0 | 4 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-crate-types-golden-1_97` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-crate-types-golden-1_97-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-package-named-build-nightly-golden` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-crate-types-golden-nightly-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `git-multi-workspace-golden-nightly` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-crate-types-golden-1_95-test` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `plan-walking-skeleton-golden-1_95` | 0.4 | 0.0 | 3 | breakbulk-plan-0.1.0.drv (0.4) |
| `products-variants-driver` | 0.4 | 0.1 | 15 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-target-views` | 0.4 | 0.2 | 22 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-libraries-negative` | 0.4 | 0.0 | 14 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-no-toolchain-references` | 0.4 | 0.1 | 22 | breakbulk-unit-0.1.0.drv (0.2) |
| `windows-dll-beside-exe` | 0.4 | 0.2 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-nextest-workspace-default` | 0.4 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-devshell-broken-manifest` | 0.4 | 0.0 | 4 | breakbulk-plan-0.1.0.drv (0.4) |
| `wasm-component-metadata` | 0.4 | 0.1 | 14 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-glibc` | 0.4 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-build-script-outputs` | 0.4 | 0.2 | 17 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-narrowing` | 0.4 | 0.1 | 19 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasm-component` | 0.4 | 0.1 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-nextest-repo` | 0.4 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-nextest-unrelated-version` | 0.4 | 0.1 | 14 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-post-link` | 0.4 | 0.1 | 21 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasip2-test-it` | 0.4 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-libraries` | 0.4 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-no-store-paths` | 0.4 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-musl-x86_64-product` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-musl-x86_64-run` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-musl-aarch64-product` | 0.3 | 0.1 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-member-defaults` | 0.3 | 0.1 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-test-only-variants` | 0.3 | 0.2 | 19 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-nonpie-product` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-nonpie-run` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasip2-test-bin` | 0.3 | 0.0 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-env-repository-path` | 0.3 | 0.2 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-all-targets` | 0.3 | 0.0 | 15 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-stamps` | 0.3 | 0.1 | 18 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasip2-test-lib` | 0.3 | 0.0 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-test-only` | 0.3 | 0.1 | 21 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-staticlib-sources` | 0.3 | 0.1 | 14 | breakbulk-unit-0.1.0.drv (0.2) |
| `android-no-runner` | 0.3 | 0.0 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-cmake-reproducible` | 0.3 | 0.0 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-test` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `same-triple-build` | 0.3 | 0.0 | 16 | breakbulk-unit-0.1.0.drv (0.2) |
| `linker-kind-mold-product` | 0.3 | 0.1 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-musl-x86_64-test` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-armv7-test` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-nonpie-nixpkgs-product` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-nonpie-nixpkgs-run` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `windows-gnullvm-aarch64-no-runner` | 0.3 | 0.0 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-source-paths` | 0.3 | 0.1 | 18 | breakbulk-unit-0.1.0.drv (0.2) |
| `windows-dll-test` | 0.3 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `darwin-x86_64` | 0.3 | 0.1 | 8 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-per-target` | 0.3 | 0.1 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-sources` | 0.3 | 0.1 | 17 | breakbulk-unit-0.1.0.drv (0.2) |
| `same-triple-test` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-cutoff-stable-inputs` | 0.3 | 0.1 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-names` | 0.3 | 0.1 | 16 | breakbulk-unit-0.1.0.drv (0.2) |
| `wasip2-run` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-optional-dependency` | 0.3 | 0.1 | 20 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-debug-info-strip` | 0.3 | 0.1 | 16 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-musl-aarch64-test` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-missing-input` | 0.3 | 0.1 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-source-paths-dwo` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `darwin-test-strip` | 0.3 | 0.1 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-product` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-run` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-rust-src` | 0.3 | 0.1 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `instantiate` | 0.3 | 0.1 | 8 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-options-strip-stage` | 0.3 | 0.1 | 16 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-clippy-strict` | 0.3 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-test-control-app` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `linux-portable-test` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-zero-config` | 0.3 | 0.1 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-test-control-repo-apps` | 0.3 | 0.0 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-source-paths-dwp` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-glibc-build-script` | 0.3 | 0.1 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-musl-aarch64-build-script` | 0.3 | 0.1 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-options-run-files` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-musl-x86_64-build-script` | 0.3 | 0.1 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-clippy-lint-groups` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-pkgconfig-musl-product` | 0.3 | 0.0 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-filtered-root` | 0.3 | 0.1 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `static-pkgconfig-musl-run` | 0.3 | 0.0 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-staticlib-dwp` | 0.3 | 0.1 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-nested-cargo-rustflags` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-select-feature-unification` | 0.3 | 0.1 | 13 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-manifest-dir` | 0.3 | 0.1 | 14 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-cargo-config-include` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-test-control-stable-dylibs` | 0.3 | 0.0 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-source-paths-dwo5` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-cdylib-debug-unpacked` | 0.3 | 0.1 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-rustc-private` | 0.3 | 0.1 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-outside-reads` | 0.3 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-out-dir-walk` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-exclusive-features` | 0.3 | 0.1 | 14 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-debug-info-keep` | 0.3 | 0.0 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-test-only-hint` | 0.3 | 0.1 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `git-multi-workspace-fetched` | 0.3 | 0.1 | 12 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-cdylib-debug-packed` | 0.3 | 0.1 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-pack-dwo-removed` | 0.3 | 0.0 | 8 | breakbulk-unit-0.1.0.drv (0.2) |
| `darwin-no-runner` | 0.3 | 0.0 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `linker-kind-mold-build-script` | 0.3 | 0.0 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-out-dir-walk-nightly` | 0.3 | 0.1 | 8 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-test-profile` | 0.3 | 0.0 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `same-triple-build-script` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-test-control-bin-exe` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-walking-skeleton-test` | 0.2 | 0.0 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-walking-skeleton` | 0.2 | 0.0 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-cfg-rustflags` | 0.2 | 0.1 | 8 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-source-paths-readme` | 0.2 | 0.0 | 11 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-package-named-build-nightly` | 0.2 | 0.1 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-pkgid-short` | 0.2 | 0.1 | 10 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-package-named-build` | 0.2 | 0.1 | 9 | breakbulk-unit-0.1.0.drv (0.2) |
| `unit-smoke` | 0.2 | 0.1 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `lazy-strings-stable` | 0.2 | 0.1 | 8 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-test-libs` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `test-runs-binary-enable` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-native-binutils` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `repository-result-names` | 0.2 | 0.0 | 5 | breakbulk-unit-0.1.0.drv (0.2) |
| `products-variants-clippy-conf` | 0.2 | 0.0 | 5 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-bin-exe-not-built` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `uefi-x86_64` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-runner-list` | 0.2 | 0.0 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `loose-ends-runner-record` | 0.2 | 0.0 | 6 | breakbulk-unit-0.1.0.drv (0.2) |
| `uefi-aarch64` | 0.2 | 0.0 | 7 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-build-script-signal` | 0.2 | 0.0 | 3 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-diagnostics-nightly` | 0.2 | 0.0 | 2 | breakbulk-unit-0.1.0.drv (0.2) |
| `plan-diagnostics` | 0.2 | 0.0 | 2 | breakbulk-unit-0.1.0.drv (0.2) |
| `formatting` | 0.1 | 0.1 | 1 | treefmt-check.drv (0.1) |
| `docs-site-links` | 0.0 | 0.0 | 2 | breakbulk-docs-site.drv (0.0) |
| `test-cutoff-run-inputs` | 0.0 | 0.0 | 1 | test-cutoff-run-inputs.drv (0.0) |
| `nix-features-gates` | 0.0 | 0.0 | 1 | nix-features-gates.drv (0.0) |
| `repository-poisoned-settings` | 0.0 | 0.0 | 1 | poisoned-settings.drv (0.0) |
| `wasm-web-tools` | 0.0 | 0.0 | 0 |  |
| `wasm-web-runner-sharing` | 0.0 | 0.0 | 0 |  |
| `wasm-bindgen-table` | 0.0 | 0.0 | 0 |  |
| `wasm-bindgen-eval` | 0.0 | 0.0 | 0 |  |
| `wasm-bindgen-build` | 0.0 | 0.0 | 0 |  |
| `wasip2-linker` | 0.0 | 0.0 | 0 |  |
| `wasi-sdk-table` | 0.0 | 0.0 | 0 |  |
| `vendor-git-inherit` | 0.0 | 0.0 | 0 |  |
| `vendor-collision` | 0.0 | 0.0 | 0 |  |
| `test-runs-test-control-skip-list` | 0.0 | 0.0 | 0 |  |
| `test-runs-test-binary-keys` | 0.0 | 0.0 | 0 |  |
| `test-runs-signal-forwarding` | 0.0 | 0.0 | 0 |  |
| `test-runs-dylib-rule` | 0.0 | 0.0 | 0 |  |
| `target-traits-rustc` | 0.0 | 0.0 | 0 |  |
| `target-traits` | 0.0 | 0.0 | 0 |  |
| `stages-zip` | 0.0 | 0.0 | 0 |  |
| `stages-wasm-web` | 0.0 | 0.0 | 0 |  |
| `stages-wasm-opt-features` | 0.0 | 0.0 | 0 |  |
| `stages-wasm-metadata` | 0.0 | 0.0 | 0 |  |
| `stages-wasm-component` | 0.0 | 0.0 | 0 |  |
| `stages-split-debug` | 0.0 | 0.0 | 0 |  |
| `stages-no-store-paths` | 0.0 | 0.0 | 0 |  |
| `stages-no-binaries` | 0.0 | 0.0 | 0 |  |
| `stages-linked-crate-types` | 0.0 | 0.0 | 0 |  |
| `stages-install` | 0.0 | 0.0 | 0 |  |
| `stages-eval` | 0.0 | 0.0 | 0 |  |
| `stages-elf-helpers` | 0.0 | 0.0 | 0 |  |
| `stages-chain` | 0.0 | 0.0 | 0 |  |
| `stages-build-script-path` | 0.0 | 0.0 | 0 |  |
| `stages-after-install` | 0.0 | 0.0 | 0 |  |
| `sources-sentinel` | 0.0 | 0.0 | 0 |  |
| `source-views` | 0.0 | 0.0 | 0 |  |
| `skeleton` | 0.0 | 0.0 | 0 |  |
| `same-triple-eval` | 0.0 | 0.0 | 0 |  |
| `roots-plans` | 0.0 | 0.0 | 0 |  |
| `roots-metadata-fixtures` | 0.0 | 0.0 | 0 |  |
| `roots-metadata-crates-io` | 0.0 | 0.0 | 0 |  |
| `repository-workspace-members` | 0.0 | 0.0 | 0 |  |
| `repository-version-req` | 0.0 | 0.0 | 0 |  |
| `repository-trim-paths-included` | 0.0 | 0.0 | 0 |  |
| `repository-tools-variant` | 0.0 | 0.0 | 0 |  |
| `repository-sys-defaults-no-switches` | 0.0 | 0.0 | 0 |  |
| `repository-sys-defaults` | 0.0 | 0.0 | 0 |  |
| `repository-stamps-invalidation` | 0.0 | 0.0 | 0 |  |
| `repository-package-sides` | 0.0 | 0.0 | 0 |  |
| `repository-package-layer-priorities` | 0.0 | 0.0 | 0 |  |
| `repository-package-layer-attr-priorities` | 0.0 | 0.0 | 0 |  |
| `repository-own-view-notes` | 0.0 | 0.0 | 0 |  |
| `repository-own-view-asset` | 0.0 | 0.0 | 0 |  |
| `repository-own-view-app` | 0.0 | 0.0 | 0 |  |
| `repository-overrides` | 0.0 | 0.0 | 0 |  |
| `repository-outside-reads-unrelated` | 0.0 | 0.0 | 0 |  |
| `repository-outside-reads-schema` | 0.0 | 0.0 | 0 |  |
| `repository-outside-reads-asset` | 0.0 | 0.0 | 0 |  |
| `repository-options-doc` | 0.0 | 0.0 | 0 |  |
| `repository-option-assertions` | 0.0 | 0.0 | 0 |  |
| `repository-nix-features` | 0.0 | 0.0 | 0 |  |
| `repository-native-preset-musl` | 0.0 | 0.0 | 0 |  |
| `repository-native-preset` | 0.0 | 0.0 | 0 |  |
| `repository-module-args` | 0.0 | 0.0 | 0 |  |
| `repository-ifd-same-plan-product` | 0.0 | 0.0 | 0 |  |
| `repository-ifd-all-outputs` | 0.0 | 0.0 | 0 |  |
| `repository-host-units-shared` | 0.0 | 0.0 | 0 |  |
| `repository-fmt` | 0.0 | 0.0 | 0 |  |
| `repository-env-lists` | 0.0 | 0.0 | 0 |  |
| `repository-devshell-trim-paths-files` | 0.0 | 0.0 | 0 |  |
| `repository-default-variant` | 0.0 | 0.0 | 0 |  |
| `repository-default-presets` | 0.0 | 0.0 | 0 |  |
| `repository-custom-json-target` | 0.0 | 0.0 | 0 |  |
| `repository-cmake-out-dir-remove` | 0.0 | 0.0 | 0 |  |
| `repository-check-groups` | 0.0 | 0.0 | 0 |  |
| `rebuild-catalog` | 0.0 | 0.0 | 0 |  |
| `products-tests-only` | 0.0 | 0.0 | 0 |  |
| `products-product-attributes` | 0.0 | 0.0 | 0 |  |
| `products-embed-invalidation` | 0.0 | 0.0 | 0 |  |
| `products-debug-info` | 0.0 | 0.0 | 0 |  |
| `presets-per-workspace` | 0.0 | 0.0 | 0 |  |
| `presets-eval` | 0.0 | 0.0 | 0 |  |
| `predict-rustc-reads` | 0.0 | 0.0 | 0 |  |
| `plan-custom-target-test-plan` | 0.0 | 0.0 | 0 |  |
| `plan-custom-target-plan` | 0.0 | 0.0 | 0 |  |
| `native-link-invalidation` | 0.0 | 0.0 | 0 |  |
| `msvc-sdk` | 0.0 | 0.0 | 0 |  |
| `msvc-debug-outputs` | 0.0 | 0.0 | 0 |  |
| `loose-ends-sys-defaults-no-package-set` | 0.0 | 0.0 | 0 |  |
| `loose-ends-devshell-target` | 0.0 | 0.0 | 0 |  |
| `llvm-versions` | 0.0 | 0.0 | 0 |  |
| `linux-portable-libraries-cxx` | 0.0 | 0.0 | 0 |  |
| `linux-portable-container-eval` | 0.0 | 0.0 | 0 |  |
| `linker-kind-rustc` | 0.0 | 0.0 | 0 |  |
| `lib-unit` | 0.0 | 0.0 | 0 |  |
| `instantiate-eval` | 0.0 | 0.0 | 0 |  |
| `hint-options` | 0.0 | 0.0 | 0 |  |
| `git-revisions-package-ids` | 0.0 | 0.0 | 0 |  |
| `git-multi-workspace-layout` | 0.0 | 0.0 | 0 |  |
| `git-multi-workspace-fetched-reference` | 0.0 | 0.0 | 0 |  |
| `flake-systems` | 0.0 | 0.0 | 0 |  |
| `env-capture-vars` | 0.0 | 0.0 | 0 |  |
| `env-capture-eval` | 0.0 | 0.0 | 0 |  |
| `docs-options-fresh` | 0.0 | 0.0 | 0 |  |
| `docs-assumptions-summary` | 0.0 | 0.0 | 0 |  |
| `default-tools` | 0.0 | 0.0 | 0 |  |
| `debug-outputs` | 0.0 | 0.0 | 0 |  |
| `darwin-eval` | 0.0 | 0.0 | 0 |  |
| `darwin-deployment-target` | 0.0 | 0.0 | 0 |  |
| `android-eval` | 0.0 | 0.0 | 0 |  |
| `accepts-feature-cargo` | 0.0 | 0.0 | 0 |  |

Builds in no check's closure (import-from-derivation during evaluation, mostly): 2.8 build-min.

Longest builds:

- 1.0 min `qhw3blhnkybck4prgmj8g871ahhijz0d-core-0.0.0-lib.drv` (1 checks)
- 1.0 min `dlx3hk1nqg3x93in6ayric79abs0skja-core-0.0.0-lib.drv` (1 checks)
- 1.0 min `crpmry26nhh127yqhgcb6n0jq5qkp21d-core-0.0.0-lib.drv` (1 checks)
- 1.0 min `4khfwks97m10qq9vwykxn7844n96pi18-test-control-ctl-lib-ctl-run.drv` (1 checks)
- 1.0 min `p5kh9nxfp0j6v0jfgwdwghps5a4y98dg-test-control-ctl-lib-ctl-run.drv` (1 checks)
- 0.7 min `156yddcprfks86v89av7w101mrvvpnkf-breakbulk-drv-0.1.0.drv` (2 checks)
- 0.5 min `a650fv3zd05jb879ac1mfcsqrd9shlwn-closure-info.drv` (1 checks)
- 0.4 min `ppw96rbnlb6cyc73s7ya8i931a187ck9-breakbulk-docs-0.1.0.drv` (2 checks)
- 0.4 min `61yyhzx5iq6bifrcpi7bp5lk7sxs6y7q-breakbulk-doctest-0.1.0.drv` (18 checks)
- 0.4 min `0gmgbwrifb2fmpvw9d2m7v9xi2nsm3n6-main-x86_64-unknown-linux-gnu-bench-bench-bencher-bench-crit-run.drv` (1 checks)
- 0.4 min `rifjnasxqc8aakx8gfdf0vvc6af2bnxz-breakbulk-plan-0.1.0.drv` (73 checks)
- 0.3 min `gpyrsnkvh43hdqda5ywnk7cbibhlx8jr-breakbulk-instantiate-0.1.0.drv` (7 checks)
- 0.3 min `xpchm3i362765rirkwkich5j5gi3qn08-differential-6.drv` (1 checks)
- 0.3 min `sv6r43jshsqf9pxzcfmfgrr10xsgc231-msvc-x86_64-pdb.drv` (1 checks)
- 0.3 min `2a1iryzh48k9fv8z50ir0v3xnaq4hy42-sys-native-golden-test.drv` (1 checks)
- 0.3 min `kfirmgyw6my8pj96s3l6nixxb8r8g068-msvc-x86_64-run.drv` (1 checks)
- 0.3 min `908wlkqri816lsc88iph9yiiadm8mcwv-breakbulk-instantiate-0.1.0.drv` (0 checks)
- 0.3 min `38idczk32dsf5v7md5i5mzv2wclck5v4-main-x86_64-pc-windows-gnullvm-default-gnu-smoke-bin-gnu-smoke-run.drv` (1 checks)
- 0.3 min `dsldhsbljszmay2cj30d0mwkagnlr27q-breakbulk-plan-0.1.0.drv` (0 checks)
- 0.3 min `ikdywzxkrsxwly1ffs253kz5nx0k39vi-windows-gnu-run.drv` (1 checks)
- 0.3 min `6wmb01ic82c5xh3hczv7xly2vrxbijb9-windows-gnullvm-run.drv` (1 checks)
- 0.3 min `mjsl19jgwgw6xw9n088kh8anf8cp0dk6-sys-native-golden-test.drv` (1 checks)
- 0.3 min `kj3lmqbaq88wzl522mfv89v7ry4aqa2n-differential-1_95-6.drv` (1 checks)
- 0.3 min `6lx8jzmx1w1mk3w49c2zzps07g569csl-sys-native-golden-build.drv` (1 checks)
- 0.3 min `c0s3mjf62ssd3wj6m3sv8gnbi9f9yrbj-main-x86_64-pc-windows-gnu-default-gnu-smoke-bin-gnu-smoke-run.drv` (1 checks)
