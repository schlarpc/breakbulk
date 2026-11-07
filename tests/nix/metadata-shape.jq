# Reduce `cargo metadata --no-deps --format-version 1` to the shape that
# tests/nix/default.nix predicts: workspace member names and, per package,
# its targets with paths relative to $root (lexically normalized; Cargo
# leaves `..` in explicit paths).
def norm:
  split("/")
  | reduce .[] as $c ([];
      if $c == "" or $c == "." then .
      elif $c == ".." and length > 0 and .[-1] != ".." then .[:-1]
      else . + [$c] end)
  | join("/");

($root + "/") as $r
| {
    members: ([.packages[].name] | sort),
    packages: (
      .packages
      | map({
          key: .name,
          value: (
            .targets
            | map({
                kind,
                crate_types,
                name,
                src_path: (.src_path | ltrimstr($r) | norm),
                test,
                doctest,
                required_features: .["required-features"]
              })
            | sort_by(.kind, .name)
          )
        })
      | from_entries
    )
  }
