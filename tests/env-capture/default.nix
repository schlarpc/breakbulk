# Checks for lib/env-capture.nix, wired into the flake's `checks.<system>`.
#
#   env-capture-eval   evaluation-time assertions: which captures are shared
#   env-capture-vars   openssl-sys captures (native, and cross to the other
#                      Linux architecture, for target and host units) and the
#                      base captures: the key variables are present, scoped to
#                      the right platform, and free of per-build values
#   unit-smoke         tests/unit-smoke: units built by breakbulk-unit with
#                      the real base capture, including a build script that
#                      compiles C; checks the C objects carry no source path
{
  pkgs,
  breakbulk,
}:
let
  inherit (pkgs) lib;
  ec = breakbulk.envCapture;

  native = pkgs;
  # Cross to the other day-one Linux architecture.
  cross =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      pkgs.pkgsCross.aarch64-multiplatform
    else
      pkgs.pkgsCross.gnu64;

  openssl =
    set: platform:
    ec.forPackage {
      pkgs = set;
      inherit platform;
      name = "openssl-sys";
      nativeInputs = p: [ p.pkg-config ];
      inputs = p: [ p.openssl ];
    };

  # What a capture for `hostSet` (the set its code is built for) must hold.
  expect =
    {
      name,
      capture,
      hostSet,
      withOpenssl,
    }:
    let
      cc = hostSet.stdenv.cc;
      prefix = cc.targetPrefix;
      salt = cc.suffixSalt;
      pkgConfig = hostSet.buildPackages.pkg-config;
      o = hostSet.openssl;
    in
    {
      inherit name;
      env = "${capture}/env.json";
      selfRefs = "${capture}/dropped-self-refs.txt";
      self = "${capture}";
      equals = {
        CC = "${prefix}gcc";
        "NIX_CC_WRAPPER_TARGET_HOST_${salt}" = "1";
        "NIX_BINTOOLS_WRAPPER_TARGET_HOST_${salt}" = "1";
        NIX_ENFORCE_PURITY = "1";
      }
      // lib.optionalAttrs withOpenssl {
        PKG_CONFIG = "${prefix}pkg-config";
        "NIX_PKG_CONFIG_WRAPPER_TARGET_HOST_${salt}" = "1";
      };
      contains = {
        PATH = [ "${cc}/bin" ] ++ lib.optional withOpenssl "${pkgConfig}/bin";
        NIX_HARDENING_ENABLE = [ "fortify" ];
      }
      // lib.optionalAttrs withOpenssl {
        NIX_CFLAGS_COMPILE = [ "-isystem ${lib.getDev o}/include" ];
        NIX_LDFLAGS = [ "-L${lib.getLib o}/lib" ];
        PKG_CONFIG_PATH = [ "${lib.getDev o}/lib/pkgconfig" ];
      };
      # strictDeps: a library's bin/ is not on PATH.
      notContains = lib.optionalAttrs withOpenssl { PATH = [ "${lib.getBin o}/bin" ]; };
      absent = [
        "SOURCE_DATE_EPOCH"
        "TMPDIR"
        "NIX_BUILD_TOP"
        "NIX_STORE"
        "NIX_BUILD_CORES"
        "HOME"
        "PWD"
        "out"
        "outputs"
        "NIX_NO_SELF_RPATH"
        "jq"
        "envTool"
      ];
      # In no value: the capture's seed, the capture's rpath.
      nowhere = [
        "-frandom-seed"
        "-rpath"
      ];
    };

  cases = [
    (expect {
      name = "native target openssl-sys";
      capture = openssl native "target";
      hostSet = native;
      withOpenssl = true;
    })
    (expect {
      name = "cross target openssl-sys";
      capture = openssl cross "target";
      hostSet = cross;
      withOpenssl = true;
    })
    (expect {
      name = "cross host openssl-sys";
      capture = openssl cross "host";
      hostSet = cross.buildPackages;
      withOpenssl = true;
    })
    (expect {
      name = "native base";
      capture = ec.base { pkgs = native; };
      hostSet = native;
      withOpenssl = false;
    })
    (expect {
      name = "cross target base";
      capture = ec.base { pkgs = cross; };
      hostSet = cross;
      withOpenssl = false;
    })
  ];

  checkVars =
    pkgs.runCommand "env-capture-vars"
      {
        nativeBuildInputs = [ pkgs.jq ];
        cases = builtins.toJSON cases;
        passAsFile = [ "cases" ];
      }
      ''
        jq -c '.[]' "$casesPath" | while read -r c; do
          name=$(jq -r .name <<<"$c")
          env=$(jq -r .env <<<"$c")
          selfRefs=$(jq -r .selfRefs <<<"$c")
          echo "checking $name ($env)"
          if [ -s "$selfRefs" ]; then
            echo "FAIL $name: dropped self-references:"
            cat "$selfRefs"
            exit 1
          fi
          problems=$(jq -r --argjson c "$c" '
            . as $e
            | ($c.equals | to_entries[] | select($e[.key] != .value)
                | "\(.key) is \($e[.key] | tojson), expected \(.value | tojson)"),
              ($c.contains | to_entries[] | .key as $k | .value[] as $n
                | select(($e[$k] // "") | contains($n) | not)
                | "\($k) lacks \($n)"),
              ($c.notContains | to_entries[] | .key as $k | .value[] as $n
                | select(($e[$k] // "") | contains($n))
                | "\($k) contains \($n)"),
              ($c.absent[] | select(. as $k | $e | has($k)) | "\(.) is present"),
              ($c.nowhere[] as $s | $e | to_entries[] | select(.value | contains($s))
                | "\(.key) contains \($s)"),
              ($e | to_entries[] | select(.value | contains($c.self))
                | "\(.key) names the capture itself")
            ' "$env")
          if [ -n "$problems" ]; then
            echo "FAIL $name:"
            echo "$problems"
            exit 1
          fi
        done
        touch $out
      '';

  same = a: b: a.drvPath == b.drvPath;

  evalChecks = {
    # On a native build, host and target captures are one derivation.
    nativeHostIsTarget = same (openssl native "host") (openssl native "target");
    # Host units of a cross build share their captures with native builds.
    crossHostIsNative = same (openssl cross "host") (openssl native "target");
    # A package without inputs gets the base capture.
    noInputsIsBase = same (ec.forPackage {
      pkgs = cross;
      name = "x";
      inputs = _: [ ];
    }) (ec.base { pkgs = cross; });
    # Cross target captures differ from native ones.
    crossTargetDiffers = !(same (openssl cross "target") (openssl native "target"));
    names =
      (openssl cross "target").name == "breakbulk-env-openssl-sys-${cross.stdenv.hostPlatform.config}"
      && (ec.base { pkgs = native; }).name == "breakbulk-env-base";
  };

  failedEval = lib.filterAttrs (_: ok: !ok) evalChecks;
in
{
  env-capture-eval =
    if failedEval == { } then
      pkgs.runCommand "env-capture-eval" { } "touch $out"
    else
      throw "env-capture-eval: failed: ${toString (lib.attrNames failedEval)}";

  env-capture-vars = checkVars;
}
