# Build-dependencies whose library code prints `rerun-if-changed`
# directives for the build script, each checked in the crate's source
# (latest release, 2026-11): source prediction reads only the script's own
# literal directives, so a package that build-depends on one keeps its
# build-script runs' whole view (`predictSources.buildScriptRuns`). Not
# prost-build (it prints none), nor cc, pkg-config or napi-build (only
# `rerun-if-env-changed`).
[
  "autocfg"
  "bindgen"
  "cxx-build"
  "glib-build-tools"
  "lalrpop"
  "slint-build"
  "tauri-build"
  "vergen"
  "vergen-lib"
]
