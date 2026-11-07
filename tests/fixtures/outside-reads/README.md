Reads outside the crate directories. The workspace is `ws/`; the
repository root holds `schema/` (read by `reader` with `include_str!`),
`assets/` (read at compile time of `app` by the `embed` proc macro, relative
to `app`'s CARGO_MANIFEST_DIR) and `unrelated/`, which nothing reads.
`packages.reader.extraSources = [ "schema" ]` and
`packages.app.extraSources = [ "assets" ]` make them visible.
