# What `mode = "auto"` would see on this evaluator.
{
  nixVersion = builtins.nixVersion;
  hasOutputOf = builtins ? outputOf;
  # First version with builder-rpc-v0 is 2.36 (unreleased; master reports
  # "2.36.0preYYYYMMDD_rev"). "2.36pre" sorts before every 2.36 prerelease.
  atLeast236pre = builtins.compareVersions builtins.nixVersion "2.36pre" >= 0;
  mode =
    if builtins ? outputOf && builtins.compareVersions builtins.nixVersion "2.36pre" >= 0
    then "dynamic" else "ifd";
}
