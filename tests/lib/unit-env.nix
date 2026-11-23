# The env a rendered unit gives its process from layers 3 to 5, without
# the env capture: Cargo's recorded `env`, then each of `envLayers`, a
# value replacing, or appending with its `sep` (breakbulk_unit::env
# `fold_layers`, which leaves out an empty side).
{ lib }:
u:
lib.foldl' (
  acc: layer:
  acc
  // lib.mapAttrs (
    k: v:
    if v.sep == "" || !(acc ? ${k}) || acc.${k} == "" then
      v.value
    else if v.value == "" then
      acc.${k}
    else
      acc.${k} + v.sep + v.value
  ) layer
) (u.env or { }) (u.envLayers or [ ])
