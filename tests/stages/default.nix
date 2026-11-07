# Checks for lib/stages.nix and lib/stage-helpers (post-link stages),
# wired into the flake's `checks.<system>`. The "linked" inputs are built
# with plain stdenv (a C program) and rust-overlay (a wasm32 cdylib), not
# by the planner.
#
#   stages-eval         evaluation-time assertions: ordering from after/
#                       before, preset chains, removal with null, `install`
#                       last, error messages for cycles, missing and
#                       ambiguous references, CA attributes, helper options
#   stages-chain        three logging stages run in the computed order;
#                       every intermediate is addressable
#   stages-split-debug  linuxGnu product of a C program (the `post-link` and
#                       `source-paths` fixture intents): gdb resolves source
#                       lines only with the debug output; a check on
#                       `linked` sees the unstripped bytes; the main output
#                       has no source reference and `debug` has one;
#                       noSourceReferences fails on an unsplit product
#   stages-elf-helpers  strip, strip --strip-all, patchelfRpath
#   stages-install      install layouts for unix, windows and wasm inputs
#   stages-zip          deterministicZip: same bytes from inputs that differ
#                       in mtimes, modes and creation order
#   stages-wasm-browser wasm32 cdylib (rust-overlay 1.99.0, wasm-bindgen
#                       0.2.130) through bindgen -> wasmOpt -> install, then
#                       loaded and called from node
#   stages-wasm-component  a core module through wasmOpt -> componentize
#                       with metadata; the component imports nothing
#
# Reproducibility of the zip stage across real rebuilds is checked by hand
# with `nix build --rebuild .#checks.x86_64-linux.stages-zip.zip` (the
# derivation is exposed as `passthru.zip`).
{
  pkgs,
  breakbulk,
}:
let
  inherit (pkgs) lib;
  S = breakbulk.stages;
  H = breakbulk.stageHelpers;

  ok = name: pkgs.runCommand name { } "touch $out";

  # --- evaluation tests -----------------------------------------------------

  dummy = _: throw "not built in evaluation tests";
  orderOf =
    stages:
    (S.explainOrder {
      name = "t";
      inherit stages;
    }).order;
  errorOf =
    stages:
    (S.explainOrder {
      name = "t";
      inherit stages;
    }).error or "";
  has = lib.hasInfix;

  evalTests = {
    testPresetLinux = {
      expr = orderOf S.defaultStages.linuxGnu;
      expected = [
        "splitDebug"
        "install"
      ];
    };
    testPresetMsvc = {
      expr = orderOf S.defaultStages.msvc;
      expected = [ "install" ];
    };
    testPresetBrowser = {
      expr = orderOf S.defaultStages.wasmBrowser;
      expected = [
        "bindgen"
        "wasmOpt"
        "install"
      ];
    };
    testPresetComponent = {
      expr = orderOf S.defaultStages.wasmComponent;
      expected = [
        "wasmOpt"
        "componentize"
        "install"
      ];
    };
    testPresetData = {
      expr = S.defaultStageNames;
      expected = {
        linuxGnu = [ "splitDebug" ];
        linuxMusl = [ "splitDebug" ];
        staticGlibc = [ "splitDebug" ];
        msvc = [ ];
        wasmBrowser = [
          "bindgen"
          "wasmOpt"
        ];
        wasmComponent = [
          "wasmOpt"
          "componentize"
        ];
      };
    };
    testUserAfter = {
      expr = orderOf (
        S.merge [
          S.defaultStages.linuxGnu
          {
            sign = {
              after = "splitDebug";
              run = dummy;
            };
          }
        ]
      );
      expected = [
        "splitDebug"
        "sign"
        "install"
      ];
    };
    testUserBefore = {
      expr = orderOf (
        S.merge [
          S.defaultStages.linuxGnu
          {
            isaFix = {
              before = "splitDebug";
              run = dummy;
            };
          }
        ]
      );
      expected = [
        "isaFix"
        "splitDebug"
        "install"
      ];
    };
    testListConstraints = {
      expr = orderOf {
        a.run = dummy;
        b = {
          after = [ "a" ];
          before = [ "c" ];
          run = dummy;
        };
        c = {
          after = "a";
          run = dummy;
        };
      };
      expected = [
        "a"
        "b"
        "c"
        "install"
      ];
    };
    # The design doc's msvc example: removing a stage the set does not have.
    testDesignExample = {
      expr = orderOf (
        S.merge [
          S.defaultStages.msvc
          {
            stageDlls = {
              after = "linked";
              run = dummy;
            };
            zip = {
              after = "stageDlls";
              run = dummy;
            };
            strip = null;
          }
        ]
      );
      expected = [
        "stageDlls"
        "zip"
        "install"
      ];
    };
    # Removing bindgen drops wasmOpt's reference to it.
    testRemoveMiddle = {
      expr =
        let
          r = S.explainOrder {
            stages = S.merge [
              S.defaultStages.wasmBrowser
              { bindgen = null; }
            ];
          };
        in
        {
          inherit (r) order removed;
        };
      expected = {
        order = [
          "wasmOpt"
          "install"
        ];
        removed = [ "bindgen" ];
      };
    };
    testRemoveInstall = {
      expr = orderOf (S.defaultStages.linuxGnu // { install = null; });
      expected = [ "splitDebug" ];
    };
    testNothing = {
      expr = orderOf { install = null; };
      expected = [ ];
    };
    # A replaced install still runs last.
    testCustomInstall = {
      expr = orderOf (
        S.defaultStages.linuxGnu
        // {
          install.run = dummy;
        }
      );
      expected = [
        "splitDebug"
        "install"
      ];
    };
    testCycle = {
      expr =
        let
          e = errorOf {
            a = {
              after = "b";
              run = dummy;
            };
            b = {
              after = "a";
              run = dummy;
            };
          };
        in
        [
          (has "cannot order the post-link stages of `t`" e)
          (has "the constraints form a cycle among a, b" e)
          (has "  a        after: b; before: -" e)
          (has "  b        after: a; before: -" e)
          (has "  linked   first (fixed)" e)
          (has "  install  after: -; before: -; runs last" e)
        ];
      expected = [
        true
        true
        true
        true
        true
        true
      ];
    };
    testAfterInstallIsCycle = {
      expr = has "cycle" (errorOf {
        late = {
          after = "install";
          run = dummy;
        };
      });
      expected = true;
    };
    testMissing = {
      expr =
        let
          e = errorOf {
            a = {
              after = "nope";
              run = dummy;
            };
            b = {
              before = "gone";
              after = "a";
              run = dummy;
            };
          };
        in
        [
          (has "`a` refers to `nope`, which is not a stage" e)
          (has "`b` refers to `gone`, which is not a stage" e)
          (has "after: a; before: gone" e)
        ];
      expected = [
        true
        true
        true
      ];
    };
    testAmbiguous = {
      expr =
        let
          e = errorOf {
            a.run = dummy;
            b.run = dummy;
          };
        in
        has "the order is ambiguous: nothing orders `a` and `b`" e;
      expected = true;
    };
    testLinkedReserved = {
      expr = has "`linked` is the fixed first stage" (errorOf {
        linked.run = dummy;
      });
      expected = true;
    };
    testBeforeLinked = {
      expr = has "nothing can run before `linked` (a)" (errorOf {
        a = {
          before = "linked";
          run = dummy;
        };
      });
      expected = true;
    };
    testOrderThrows = {
      expr =
        (builtins.tryEval (
          S.order {
            stages = {
              a.after = "b";
              b.after = "a";
            };
          }
        )).success;
      expected = false;
    };
    # Nothing on this evaluator says ca-derivations is on.
    testCaAuto = {
      expr = S.caAuto == (builtins ? outputOf);
      expected = true;
    };
    # With ca = true, stages and checks carry the CA attributes (not
    # instantiated: that needs the experimental feature); linked does not.
    testCaAttrs = {
      expr =
        let
          p = S.mkProduct {
            name = "ca";
            linked = helloLinked;
            stages = S.defaultStages.linuxGnu;
            inherit pkgs;
            ca = true;
          };
          isCa = d: (d.drvAttrs.__contentAddressed or false) && d.drvAttrs.outputHashMode == "recursive";
        in
        [
          p.ca
          (isCa p.stages.splitDebug)
          (isCa p.stages.install)
          (isCa p.checks.noSourceReferences)
          (p.stages.linked.drvAttrs ? __contentAddressed)
        ];
      expected = [
        true
        true
        true
        true
        false
      ];
    };
    testCaOff = {
      expr = hello.ca || hello.stages.splitDebug.drvAttrs ? __contentAddressed;
      expected = false;
    };
    testProductAttrs = {
      expr = {
        stages = lib.attrNames hello.stages;
        order = hello.stageOrder;
        checks = lib.attrNames hello.checks;
        debugIsSplit = hello.debug.drvPath == hello.stages.splitDebug.debug.drvPath;
        productIsInstall = hello.drvPath == hello.stages.install.drvPath;
      };
      expected = {
        stages = [
          "install"
          "linked"
          "splitDebug"
        ];
        order = [
          "splitDebug"
          "install"
        ];
        checks = [
          "noSourceReferences"
          "stripped"
          "unstripped"
        ];
        debugIsSplit = true;
        productIsInstall = true;
      };
    };
    testCheckOnMissingStage = {
      expr =
        (builtins.tryEval
          (S.mkProduct {
            name = "x";
            linked = helloLinked;
            inherit pkgs;
            checks.c = {
              on = "strip";
              run = { input, ... }: input;
            };
          }).checks.c
        ).success;
      expected = false;
    };
    testRemoveDefaultCheck = {
      expr =
        lib.attrNames
          (S.mkProduct {
            name = "x";
            linked = helloLinked;
            inherit pkgs;
            checks.noSourceReferences = null;
          }).checks;
      expected = [ ];
    };
    testHelperConfigured = {
      expr = builtins.isFunction (H.wasmOpt { flags = [ "-O3" ]; });
      expected = true;
    };
    testHelperUnknownOption = {
      expr = (builtins.tryEval (H.wasmOpt { flag = [ "-O3" ]; })).success;
      expected = false;
    };
  };
  evalFailures = lib.debug.runTests evalTests;

  # --- a C program as the raw link output -------------------------------------

  # A store path, so that its debug info names a source store path, as a
  # breakbulk unit's does.
  helloSrc = ./fixtures/hello-c;
  # NIX_NO_SELF_RPATH as in breakbulk env captures: otherwise the linker
  # wrapper adds an rpath to $out/lib, which only fixup would remove.
  helloLinked = pkgs.runCommandCC "hello-linked" { NIX_NO_SELF_RPATH = 1; } ''
    mkdir $out
    $CC -g -O0 -Wl,--build-id=sha1 ${helloSrc}/hello.c -o $out/hello
  '';

  readelfBin = "${pkgs.binutils-unwrapped-all-targets}/bin/readelf";

  hello = S.mkProduct {
    name = "hello";
    linked = helloLinked;
    stages = S.defaultStages.linuxGnu;
    target.triple = "x86_64-unknown-linux-gnu";
    sourcePaths = [ helloSrc ];
    inherit pkgs;
    checks = {
      # A check on `linked` sees the bytes before splitDebug.
      unstripped = {
        on = "linked";
        run =
          {
            input,
            product,
            pkgs,
          }:
          pkgs.runCommand "${product.name}-unstripped" { } ''
            ${readelfBin} -S -W ${input}/hello | grep -q ' \.debug_info '
            touch $out
          '';
      };
      stripped.run =
        { input, pkgs, ... }:
        pkgs.runCommand "hello-stripped" { } ''
          if ${readelfBin} -S -W ${input}/bin/hello | grep -q ' \.debug_info '; then
            echo "product still has debug info"; exit 1
          fi
          touch $out
        '';
    };
  };

  # Without splitDebug the product's main output references the source.
  helloUnsplit = S.mkProduct {
    name = "hello-unsplit";
    linked = helloLinked;
    stages = { };
    sourcePaths = [ helloSrc ];
    inherit pkgs;
  };

  closureOf = d: "${pkgs.closureInfo { rootPaths = [ d ]; }}/store-paths";

  # --- chain -----------------------------------------------------------------

  logStage =
    n:
    { input, pkgs, ... }:
    pkgs.runCommand "log-${n}" { } ''
      mkdir $out
      cp ${input}/log $out/log
      chmod u+w $out/log
      echo ${n} >> $out/log
    '';
  logged = S.mkProduct {
    name = "logged";
    linked = pkgs.runCommand "log-linked" { } "mkdir $out; echo linked > $out/log";
    inherit pkgs;
    stages = {
      c = {
        after = "b";
        run = logStage "c";
      };
      a = {
        before = "b";
        run = logStage "a";
      };
      b.run = logStage "b";
      install = null;
    };
  };

  # --- wasm ------------------------------------------------------------------

  rust = pkgs.rust-bin.stable."1.99.0".minimal.override { targets = [ "wasm32-unknown-unknown" ]; };
  wasmSrc = ./fixtures/wasm-hello;
  wasmLock = ./fixtures/wasm-hello/Cargo.lock;
  wasmVendor = pkgs.rustPlatform.importCargoLock { lockFile = wasmLock; };
  wasmLinked = pkgs.runCommand "wasm-hello-linked" { nativeBuildInputs = [ rust ]; } ''
    export CARGO_HOME=$TMPDIR/cargo-home
    mkdir -p $CARGO_HOME
    cat > $CARGO_HOME/config.toml <<EOF
    [source.crates-io]
    replace-with = "vendored"
    [source.vendored]
    directory = "${wasmVendor}"
    EOF
    cp -R ${wasmSrc} src
    chmod -R u+w src
    cd src
    cargo build --offline --locked --release --target wasm32-unknown-unknown
    mkdir $out
    cp target/wasm32-unknown-unknown/release/wasm_hello.wasm $out/
  '';
  wasmBrowser = S.mkProduct {
    name = "wasm-hello";
    linked = wasmLinked;
    stages = S.defaultStages.wasmBrowser;
    target.triple = "wasm32-unknown-unknown";
    info.lockfile = wasmLock;
    inherit pkgs;
  };

  addLinked = pkgs.runCommand "adder-linked" { nativeBuildInputs = [ pkgs.wasm-tools ]; } ''
    mkdir $out
    cat > add.wat <<'EOF'
    (module
      (func (export "add") (param i32 i32) (result i32)
        local.get 0
        local.get 1
        i32.add))
    EOF
    wasm-tools parse add.wat -o $out/adder.wasm
  '';
  component = S.mkProduct {
    name = "adder";
    linked = addLinked;
    stages = S.merge [
      S.defaultStages.wasmComponent
      {
        componentize.run = H.componentize {
          metadata = {
            name = "adder";
            language.Rust = "1.99.0";
            processedBy.breakbulk = "0.0.0";
          };
        };
      }
    ];
    target.triple = "wasm32-unknown-unknown";
    inherit pkgs;
  };

  # --- zip -------------------------------------------------------------------

  # Two trees with the same files, made in different orders, with different
  # times and modes.
  tree =
    name: reverse:
    pkgs.runCommand name { } ''
      mkdir -p $out
      cd $out
      mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$1" > "$1"; touch -d "@$2" "$1"; }
      ${
        if reverse then
          ''
            mk z/last.txt 2000000000; mk b.txt 1700000000; mk a.txt 1600000000
            chmod 0775 b.txt
          ''
        else
          ''
            mk a.txt 1000000000; mk b.txt 1100000000; mk z/last.txt 1200000000
            chmod 0700 b.txt
          ''
      }
    '';
  zipOf =
    t:
    H.deterministicZip {
      input = t;
      product.name = "bundle";
      target = { };
      inherit pkgs;
    };
  zipA = zipOf (tree "tree-a" false);
  zipB = zipOf (tree "tree-b" true);

  # --- install ---------------------------------------------------------------

  installOf =
    triple: files:
    H.install {
      input = pkgs.runCommand "install-in-${triple}" { } ''
        mkdir -p $out/share/doc
        cd $out
        echo doc > share/doc/README
        ${lib.concatMapStrings (f: ''
          echo ${f.name} > ${f.name}
          ${lib.optionalString (f.x or false) "chmod +x ${f.name}"}
        '') files}
      '';
      product.name = "inst";
      target = { inherit triple; };
      inherit pkgs;
    };
  installUnix = installOf "x86_64-unknown-linux-gnu" [
    {
      name = "app";
      x = true;
    }
    {
      name = "libfoo.so";
      x = true;
    }
    { name = "libfoo.so.1"; }
    { name = "libbar.a"; }
    { name = "notes.txt"; }
  ];
  installWindows = installOf "x86_64-pc-windows-msvc" [
    { name = "app.exe"; }
    { name = "app.pdb"; }
    { name = "vcruntime140.dll"; }
    { name = "app.lib"; }
    { name = "notes.txt"; }
  ];
  installWasm = installOf "wasm32-unknown-unknown" [
    { name = "ui.js"; }
    { name = "ui_bg.wasm"; }
  ];

  stageArgs = input: {
    inherit input pkgs;
    product.name = "hello";
    target = { };
  };
in
{
  stages-eval =
    if evalFailures == [ ] then
      ok "stages-eval"
    else
      throw "stages-eval: ${builtins.toJSON evalFailures}";

  stages-chain = pkgs.runCommand "stages-chain" { } ''
    set -eu
    test "$(cat ${logged}/log)" = "$(printf 'linked\na\nb\nc')"
    test "$(cat ${logged.stages.a}/log)" = "$(printf 'linked\na')"
    test "$(cat ${logged.stages.b}/log)" = "$(printf 'linked\na\nb')"
    test "${toString logged.stageOrder}" = "a b c"
    touch $out
  '';

  stages-split-debug =
    pkgs.runCommand "stages-split-debug"
      {
        nativeBuildInputs = [
          pkgs.gdb
          pkgs.binutils-unwrapped-all-targets
        ];
        checks = lib.attrValues hello.checks;
        unsplitFails = pkgs.testers.testBuildFailure helloUnsplit.checks.noSourceReferences;
      }
      ''
        set -euo pipefail
        exe=${hello}/bin/hello
        test "$($exe)" = "hello 42"

        # The debug file sits at its build-id path, and the debuglink names it.
        id=$(readelf -n $exe | sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p')
        test ''${#id} = 40
        dbg=${hello.debug}/lib/debug/.build-id/''${id:0:2}/''${id:2}.debug
        test -f "$dbg"
        # (readelf complains that the .debug file's .interp has no contents.)
        readelf -S -W "$dbg" > dbg-sections.txt 2>/dev/null || true
        grep -q ' \.debug_info ' dbg-sections.txt
        readelf --string-dump=.gnu_debuglink $exe | grep -q "''${id:2}.debug"
        if readelf -S -W $exe | grep -q ' \.debug_'; then echo "main output has debug sections"; exit 1; fi
        # The symbol table stays (splitDebug strips debug info only).
        readelf -s -W $exe | grep -q ' answer$'

        # gdb finds source lines through debug-file-directory (set with -iex,
        # before the executable is loaded) ...
        export NIX_DEBUG_INFO_DIRS=
        gdb -batch -nx -iex 'set debug-file-directory ${hello.debug}/lib/debug' \
          -ex 'info line answer' -ex 'list answer' $exe > with.txt 2>&1
        cat with.txt
        grep -q 'Line 4 of "${helloSrc}/hello.c"' with.txt
        grep -q 'int doubled = x \* 2;' with.txt
        # ... and not without it.
        gdb -batch -nx -iex 'set debug-file-directory /nonexistent' \
          -ex 'info line answer' -ex 'list answer' $exe > without.txt 2>&1 || true
        cat without.txt
        if grep -q 'int doubled' without.txt; then echo "gdb found sources without the debug output"; exit 1; fi

        # The main output's closure has no source; the debug output's does.
        if grep -qxF ${helloSrc} ${closureOf hello}; then echo "product references the source"; exit 1; fi
        grep -qxF ${helloSrc} ${closureOf hello.debug}

        # noSourceReferences fails on an unsplit product, naming the source.
        test "$(cat $unsplitFails/testBuildFailure.exit)" = 1
        grep -q 'references source ${helloSrc}' $unsplitFails/testBuildFailure.log
        touch $out
      '';

  stages-elf-helpers =
    let
      stripped = H.strip (stageArgs helloLinked);
      strippedAll = H.strip { all = true; } (stageArgs helloLinked);
      rpathed = H.patchelfRpath { libs = [ pkgs.zlib ]; } (stageArgs helloLinked);
    in
    pkgs.runCommand "stages-elf-helpers"
      { nativeBuildInputs = [ pkgs.binutils-unwrapped-all-targets ]; }
      ''
        set -euo pipefail
        if readelf -S -W ${stripped}/hello | grep -q ' \.debug_'; then exit 1; fi
        readelf -S -W ${stripped}/hello | grep -q ' \.symtab '
        if readelf -S -W ${strippedAll}/hello | grep -q ' \.symtab '; then exit 1; fi
        test "$(${strippedAll}/hello)" = "hello 42"
        readelf -d ${rpathed}/hello | grep -E 'R(UN)?PATH' | grep -qF '${pkgs.zlib}/lib'
        test "$(${rpathed}/hello)" = "hello 42"
        touch $out
      '';

  stages-install = pkgs.runCommand "stages-install" { } ''
    set -eu
    u=${installUnix}; w=${installWindows}; a=${installWasm}
    test -x $u/bin/app
    test -f $u/lib/libfoo.so; test -f $u/lib/libfoo.so.1; test -f $u/lib/libbar.a
    test -f $u/notes.txt; test -f $u/share/doc/README
    test -f $w/bin/app.exe; test -f $w/bin/app.pdb; test -f $w/bin/vcruntime140.dll
    test -f $w/lib/app.lib; test -f $w/notes.txt
    test -f $a/pkg/ui.js; test -f $a/pkg/ui_bg.wasm; test -f $a/pkg/share/doc/README
    test "$(ls $a)" = pkg
    touch $out
  '';

  stages-zip =
    pkgs.runCommand "stages-zip"
      {
        nativeBuildInputs = [ pkgs.unzip ];
        passthru.zip = zipA;
      }
      ''
        set -euo pipefail
        cmp ${zipA}/bundle.zip ${zipB}/bundle.zip
        zipinfo ${zipA}/bundle.zip
        test "$(zipinfo -1 ${zipA}/bundle.zip | tr '\n' ' ')" = "a.txt b.txt z/last.txt "
        zipinfo -T ${zipA}/bundle.zip | grep -c '19800101.000000' | grep -qx 3
        zipinfo ${zipA}/bundle.zip | grep -q '^-rwxr-xr-x .* b.txt$'
        zipinfo ${zipA}/bundle.zip | grep -q '^-rw-r--r-- .* a.txt$'
        touch $out
      '';

  stages-wasm-browser =
    pkgs.runCommand "stages-wasm-browser"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.wasm-tools
        ];
      }
      ''
        set -euo pipefail
        pkg=${wasmBrowser}/pkg
        ls -l $pkg
        test -f $pkg/wasm_hello.js
        test -f $pkg/wasm_hello.d.ts
        wasm-tools validate --features all $pkg/wasm_hello_bg.wasm
        before=$(stat -c %s ${wasmBrowser.stages.bindgen}/wasm_hello_bg.wasm)
        after=$(stat -c %s $pkg/wasm_hello_bg.wasm)
        echo "bindgen: $before bytes; wasmOpt: $after bytes"
        test "$after" -lt "$before"
        cp $pkg/wasm_hello.js wasm_hello.mjs
        cat > run.mjs <<EOF
        import { initSync, greet } from "./wasm_hello.mjs";
        import { readFileSync } from "node:fs";
        initSync({ module: readFileSync("$pkg/wasm_hello_bg.wasm") });
        console.log(greet("nix"));
        EOF
        test "$(node run.mjs)" = "hello, nix"
        touch $out
      '';

  stages-wasm-component =
    pkgs.runCommand "stages-wasm-component" { nativeBuildInputs = [ pkgs.wasm-tools ]; }
      ''
        set -euo pipefail
        c=${component}/pkg/adder.wasm
        wasm-tools print $c > print.txt
        head -n1 print.txt | grep -q '^(component'
        wasm-tools component wit $c | tee wit.txt
        if grep -q import wit.txt; then echo "component has imports"; exit 1; fi
        wasm-tools metadata show $c | tee meta.txt
        grep -q 'adder' meta.txt
        grep -q 'Rust.*1.99.0' meta.txt
        grep -q 'breakbulk.*0.0.0' meta.txt
        touch $out
      '';
}
