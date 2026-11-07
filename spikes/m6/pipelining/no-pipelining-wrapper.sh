#!/usr/bin/env bash
# RUSTC_WRAPPER that turns Cargo's pipelining off: it drops rustc's
# `"emit":"metadata"` artifact notification, so Cargo learns about the rmeta
# only when rustc exits. Cargo then releases rmeta-only dependents at the end
# (cargo src/compiler/job_queue/job_state.rs: a job that finishes without
# `rmeta_produced` gets its Metadata finish with the All finish), which is
# the schedule breakbulk's one-derivation-per-library has. `build.pipelining
# = false` no longer does anything in Cargo 1.99 (only the schema field is
# left).
exec "$@" 2> >(grep --line-buffered -vF '"emit":"metadata"' >&2)
