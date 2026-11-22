# The Nix features breakbulk may use, and the only place it uses them
# ("nixFeatures" in docs/src/reference/outputs.md).
#
#   g = breakbulk.nixFeatures;
#   g.available              the evaluator has dynamic derivations: the
#                            `outputOf` builtin, on Nix 2.36 or later
#   g.defaultMode            "dynamic" when `available`, else "ifd"
#   g.defaultCa              `defaultMode == "dynamic"`
#   g.standalone { ca ? false; dynamic ? false; }
#                            the record a lib function called outside
#                            mkRepository uses by default: what its own
#                            arguments ask for, and import from derivation
#   g.caAttrs record site    the attributes of a floating content-addressed
#                            derivation (recursive, sha256)
#   g.outputOf record site drvPath output
#                            builtins.outputOf
#   g.readOutput record site path
#                            builtins.readFile of a derivation's output, at
#                            evaluation time (import from derivation)
#
# A record is `repo.nixFeatures`: { caDerivations; dynamicDerivations;
# importFromDerivation; }. Every use of a feature goes through its gate,
# which throws, naming `site`, when the record says the feature is off: a
# record that leaves out a feature the evaluation reaches fails there, not
# at a Nix error far from the cause.
{ lib }:
let
  # Nix's names, for the messages.
  nixNames = {
    caDerivations = "the `ca-derivations` experimental feature";
    dynamicDerivations = "the `dynamic-derivations` experimental feature";
    importFromDerivation = "import from derivation (`allow-import-from-derivation`)";
  };

  gate =
    feature: record: site: v:
    if record.${feature} then
      v
    else
      throw "breakbulk: ${site} needs ${nixNames.${feature}}, which `nixFeatures.${feature}` says this evaluation does not use";

  # `builtins ? outputOf` is true exactly when the evaluator has the
  # `dynamic-derivations` feature (primops gated on a disabled feature are
  # not registered); builder-rpc-v0 is on Nix master since 2026-07-21 and
  # first released in 2.36. Master reports `2.36.0pre…`, which compares
  # below "2.36", hence "2.36pre". Determinate Nix reports its upstream
  # base (2.35.x) and lacks builder-rpc-v0.
  available = builtins ? outputOf && builtins.compareVersions builtins.nixVersion "2.36pre" >= 0;

  defaultMode = if available then "dynamic" else "ifd";
in
{
  inherit available defaultMode;

  # Nix code cannot tell whether `ca-derivations` is on (no builtin is
  # gated on it, and `builtins.tryEval` does not catch the missing-feature
  # error), but dynamic-derivation mode needs it, so its default follows
  # the mode.
  defaultCa = defaultMode == "dynamic";

  hasOutputOf = builtins ? outputOf;

  standalone =
    {
      ca ? false,
      dynamic ? false,
    }:
    {
      caDerivations = ca || dynamic;
      dynamicDerivations = dynamic;
      importFromDerivation = true;
    };

  caAttrs =
    record: site:
    gate "caDerivations" record site {
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
    };

  outputOf =
    record: site: drvPath: output:
    gate "dynamicDerivations" record site (builtins.outputOf drvPath output);

  readOutput =
    record: site: path:
    gate "importFromDerivation" record site (builtins.readFile path);
}
