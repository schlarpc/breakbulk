# The `buildScriptPaths` check of one plan ("Missing build-script paths" in
# docs/src/explanation/internals/products.md): it fails when a build-script
# run of the plan, on either platform, declared a `rerun-if-changed` path
# that was not in its view, naming each path, the run's package and
# platform and the option to add the path to.
#
#   buildScriptPaths.mkCheck {
#     pkgs;
#     name;          # the derivation's name
#     plan;          # the plan, in the failure message
#     runs;          # `{ runsFile; }`: a file listing the runs' `flags`
#                    # outputs (the instantiation's `buildScriptRuns`)
#     targetName;    # the target platform, in the failure message
#     allow = [ { package; version; path; } … ];
#                    # missing paths the scripts do not need: `path` is a
#                    # shell glob pattern over the path as printed
#   }
#
# `$out/allowed` lists the allowed paths it found, one per line.
#
# A check rather than a failing run: the run's failure would block
# everything above it and name one path, where the check names every path
# of the plan at once and the plan still builds.
{ lib }:
{
  mkCheck =
    {
      pkgs,
      name,
      plan,
      runs,
      targetName,
      allow ? [ ],
    }:
    let
      jq = "${pkgs.buildPackages.jq}/bin/jq";
    in
    pkgs.runCommand name
      {
        allowJson = builtins.toJSON allow;
        inherit plan targetName;
      }
      ''
        set -euo pipefail
        mkdir -p $out
        : > $out/allowed
        # package <TAB> version <TAB> platform <TAB> declared <TAB> hint, one
        # per missing path.
        for f in $(cat ${runs.runsFile}); do
          [ -e "$f/missing-paths.json" ] || continue
          ${jq} -r --slurpfile md "$f/metadata.json" \
            '.[] | [$md[0].package, $md[0].version, $md[0].platform, .declared, .hint] | @tsv' "$f/missing-paths.json"
        done | LC_ALL=C sort -u > missing
        bad=()
        declare -A allowItems=() suggested=()
        while IFS=$'\t' read -r package version platform declared hint; do
          ok=0
          while IFS=$'\t' read -r ap av apath; do
            # Unquoted: a glob pattern.
            if [ "$package" = "$ap" ] && [ "$version" = "$av" ] && [[ $declared == $apath ]]; then ok=1; break; fi
          done < <(${jq} -r '.[] | [.package, .version, .path] | @tsv' <<< "$allowJson")
          case $platform in
            host) where="for the build machine" ;;
            *) where="for $targetName" ;;
          esac
          if [ "$ok" = 1 ]; then
            echo "buildScriptPaths: $package $version ($where) declares $declared, which is not in its view: allowed" >&2
            printf '%s %s (%s): %s\n' "$package" "$version" "$where" "$declared" >> $out/allowed
          else
            bad+=("$package $version ($where): $hint")
            if [ -z "''${suggested[$package/$declared]-}" ]; then
              suggested[$package/$declared]=1
              allowItems[$package]+="$(${jq} -n --arg s "$declared" '$s') "
            fi
          fi
        done < missing
        if [ ''${#bad[@]} -gt 0 ]; then
          {
            echo "buildScriptPaths: build scripts of $plan declared rerun-if-changed paths that were not in their view, so they ran without them:"
            printf '  %s\n' "''${bad[@]}"
            echo "When a script does not need a path, allow it:"
            for p in $(printf '%s\n' "''${!allowItems[@]}" | LC_ALL=C sort); do
              echo "  packages.$p.buildScriptPaths.allow = [ ''${allowItems[$p]}];"
            done
          } >&2
          exit 1
        fi
      '';
}
