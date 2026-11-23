# The registries every repository knows, as `registries.<name>` entries.
# A definition of the same name replaces them field by field (a mirror sets
# `crates-io.dl`).
{
  crates-io = {
    index = "https://github.com/rust-lang/crates.io-index";
    dl = "https://static.crates.io/crates/{crate}/{crate}-{version}.crate";
  };
}
