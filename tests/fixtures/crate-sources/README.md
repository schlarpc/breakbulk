Crates from crates.io whose sources do not come from crates.io.

- `breakbulk-test-prevendored` is not on crates.io. vendored/ holds it as
  `cargo vendor` writes it, with a `.cargo-checksum.json` whose file hash
  is wrong. A `crateSources` function supplies it; breakbulk replaces that
  file, so Cargo does not check the file hash.
- `itoa` is downloaded from a mirror (a `file://` directory) through a
  `fetch` that renames the download, so the mirror is really used. A
  `crateSources` function patches it: its `src/lib.rs` gains `PATCHED`.

app prints `42 7`.
