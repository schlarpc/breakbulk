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
#   stages-split-debug  Linux product of a C program (the `post-link` and
#                       `source-paths` fixture intents): gdb resolves source
#                       lines only with the debug output; a check on
#                       `linked` sees the unstripped bytes; the main output
#                       has no source reference and `debug` has one;
#                       noSourceReferences fails on an unsplit product
#   stages-elf-helpers  strip, strip --strip-all, patchelfRpath
#   stages-install      install layouts for unix (Linux, Apple), windows
#                       (msvc, MinGW) and wasm inputs
#   stages-no-store-paths  noStorePaths names every store path in any
#                       file's bytes, and passes once each is allowed
#   stages-zip          deterministicZip: same bytes from inputs that differ
#                       in mtimes, modes and creation order
#   stages-wasm-web wasm32 cdylib (rust-overlay 1.99.0, wasm-bindgen
#                       0.2.130) through bindgen -> wasmOpt -> install, then
#                       loaded and called from node
#   stages-linked-crate-types  the `linked` stage of a cdylib+staticlib
#                       library: two roots over one unit output
#   stages-no-binaries  a product whose roots were all
#                       skipped (dynamic mode) holds the no-binaries marker,
#                       and every stage and check passes it on without
#                       running; with a built root, stages run
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
    # The stage `debugInfo = "split"` inserts (lib/products.nix).
    testDebugSplitChain = {
      expr = orderOf (S.chain [ "splitDebug" ]);
      expected = [
        "splitDebug"
        "install"
      ];
    };
    testNoStages = {
      expr = orderOf { };
      expected = [ "install" ];
    };
    testPresetBrowser = {
      expr = orderOf S.defaultStages.wasmWeb;
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
        wasmWeb = [
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
          (S.chain [ "splitDebug" ])
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
          (S.chain [ "splitDebug" ])
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
          { }
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
              S.defaultStages.wasmWeb
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
      expr = orderOf ((S.chain [ "splitDebug" ]) // { install = null; });
      expected = [ "splitDebug" ];
    };
    testNothing = {
      expr = orderOf { install = null; };
      expected = [ ];
    };
    # A replaced install still runs last.
    testCustomInstall = {
      expr = orderOf (
        (S.chain [ "splitDebug" ])
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
            stages = S.chain [ "splitDebug" ];
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
    stages = S.chain [ "splitDebug" ];
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
    stages = S.defaultStages.wasmWeb;
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
  # MinGW: a staticlib and an import library end in `.a` (#17).
  installWindowsGnu = installOf "x86_64-pc-windows-gnu" [
    { name = "app.exe"; }
    { name = "foo.dll"; }
    { name = "libfoo.dll.a"; }
    { name = "libbar.a"; }
    { name = "notes.txt"; }
  ];
  installApple = installOf "aarch64-apple-darwin" [
    {
      name = "app";
      x = true;
    }
    {
      name = "libfoo.dylib";
      x = true;
    }
    { name = "libbar.a"; }
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
    g=${installWindowsGnu}; m=${installApple}
    test -x $u/bin/app
    test -f $u/lib/libfoo.so; test -f $u/lib/libfoo.so.1; test -f $u/lib/libbar.a
    test -f $u/notes.txt; test -f $u/share/doc/README
    test -f $w/bin/app.exe; test -f $w/bin/app.pdb; test -f $w/bin/vcruntime140.dll
    test -f $w/lib/app.lib; test -f $w/notes.txt
    test -f $a/pkg/ui.js; test -f $a/pkg/ui_bg.wasm; test -f $a/pkg/share/doc/README
    test "$(ls $a)" = pkg
    test -f $g/bin/app.exe; test -f $g/bin/foo.dll; test -f $g/lib/libfoo.dll.a
    test -f $g/lib/libbar.a; test -f $g/notes.txt
    test -x $m/bin/app; test -f $m/lib/libfoo.dylib; test -f $m/lib/libbar.a; test -f $m/notes.txt
    touch $out
  '';

  # noStorePaths finds every store path named in any file's
  # bytes (an ELF binary's string, a text file, a path whose hash
  # remove-references-to replaced), naming file and path, and passes once
  # each is allowed, by glob or by store path.
  stages-no-store-paths =
    let
      ref = pkgs.hello;
      product = pkgs.runCommand "store-strings" { } ''
        mkdir -p $out/bin $out/share
        # Binary bytes around the string, as in a linked program.
        printf '\177ELF\002\001\001\000\000conf=%s/etc/ssl\000\377\376' \
          /nix/store/0123456789abcdfghijklmnpqrsvwxyz-openssl-3.5.9-etc > $out/bin/hello
        printf 'modules=/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-openssl-3.5.9/lib/ossl-modules\n' > $out/share/conf
        echo "tool=${ref}/bin/hello" >> $out/share/conf
        echo "/nix/store/too-short-openssl" > $out/share/fine
      '';
      run = h: h {
        input = product;
        product.name = "p";
        inherit pkgs;
      };
      strict = H.noStorePaths { why = "test"; };
      allowed = H.noStorePaths {
        allow = [
          "*-openssl-*"
          ref
        ];
      };
      clean = H.noStorePaths { } {
        input = pkgs.runCommand "clean" { } "mkdir -p $out/bin; echo /etc/ssl > $out/bin/x";
        product.name = "clean";
        inherit pkgs;
      };
    in
    pkgs.runCommand "stages-no-store-paths"
      {
        failure = pkgs.testers.testBuildFailure (run strict);
        allowedOut = run allowed;
        inherit clean;
        refPath = "${ref}";
      }
      ''
        set -euo pipefail
        log=$failure/testBuildFailure.log
        cat $log
        grep -qF 'noStorePaths: p: bin/hello names the Nix store path /nix/store/0123456789abcdfghijklmnpqrsvwxyz-openssl-3.5.9-etc/etc/ssl: test' $log
        grep -qF 'noStorePaths: p: share/conf names the Nix store path /nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-openssl-3.5.9/lib/ossl-modules: test' $log
        grep -qF "noStorePaths: p: share/conf names the Nix store path $refPath/bin/hello: test" $log
        if grep -q 'share/fine' $log; then echo "a short path matched" >&2; exit 1; fi
        test "$(grep -c 'noStorePaths: p:' $log)" = 3
        cat $allowedOut/allowed
        test "$(wc -l < $allowedOut/allowed)" = 3
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

  stages-wasm-web =
    pkgs.runCommand "stages-wasm-web"
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

  # A library with crate-type = ["cdylib", "staticlib"]: one unit output,
  # two roots. The `linked` stage links each file once.
  stages-linked-crate-types =
    let
      unitOut = pkgs.runCommand "fake-unit" { } ''
        mkdir $out; echo so > $out/libfoo.so; echo a > $out/libfoo.a
      '';
      root =
        kind:
        unitOut
        // {
          breakbulkRoot = {
            package = "foo";
            target = "foo";
            inherit kind;
            test = false;
            unit = "c-1";
            reason = null;
          };
        };
      linked =
        (breakbulk.products.mkProducts {
          inherit pkgs;
          inst = {
            roots = {
              "foo/cdylib/foo" = root "cdylib";
              "foo/staticlib/foo" = root "staticlib";
            };
            sources = {
              workspace = { };
              crates = { };
            };
          };
          triple = "x86_64-unknown-linux-gnu";
          ca = false;
        }).foo.stages.linked;
    in
    pkgs.runCommand "stages-linked-crate-types" { } ''
      test "$(ls ${linked} | tr '\n' ' ')" = "libfoo.a libfoo.so "
      touch $out
    '';

  # A dynamic-mode product whose roots Cargo all skipped. Its
  # `linked` holds only the no-binaries marker, and every stage and check
  # (splitDebug, a stage and a check that would fail, a stage with
  # structured attributes, a stage and a check written as bare `derivation`
  # calls, noSourceReferences) passes the marker on to
  # each output without running. A product with a built root runs its
  # stages as usual.
  stages-no-binaries =
    let
      wrapper =
        name: notBuilt:
        pkgs.runCommand "wrapper-${name}" { } (
          if notBuilt then
            ''
              mkdir $out
              echo "${name}: needs feature cli" > $out/not-built
            ''
          else
            ''
              mkdir -p $out/root
              echo bin > $out/root/${name}
            ''
        );
      root = name: notBuilt: {
        breakbulkRoot = {
          package = "p";
          target = name;
          kind = "bin";
          test = false;
          unit = "c-${name}";
          reason = null;
          dynamic = true;
          wrapper = wrapper name notBuilt;
          requiredFeatures = [ "cli" ];
        };
      };
      fails =
        n:
        { pkgs, ... }:
        pkgs.runCommand n { } "echo ${n} ran; exit 1";
      # A stage and a check written as a bare `derivation` call (decision
      # 147), which `overrideAttrs` cannot wrap.
      raw =
        n: script:
        { pkgs, ... }:
        derivation {
          name = n;
          inherit (pkgs.stdenv.hostPlatform) system;
          builder = "${pkgs.bash}/bin/bash";
          args = [
            "-c"
            script
          ];
        };
      productOf =
        {
          roots,
          ca ? false,
        }:
        (breakbulk.products.mkProducts {
          inherit pkgs ca;
          inst = {
            inherit roots;
            sources = {
              workspace = { };
              crates = { };
            };
          };
          triple = "x86_64-unknown-linux-gnu";
          targetStages = {
            boom = {
              before = "splitDebug";
              run = fails "boom";
            };
            structured = {
              after = "splitDebug";
              run =
                { pkgs, ... }:
                pkgs.runCommand "structured" {
                  __structuredAttrs = true;
                  outputs = [
                    "out"
                    "extra"
                  ];
                } "exit 1";
            };
            rawStage = {
              after = "structured";
              run = raw "raw-stage" "echo raw stage ran; exit 1";
            };
          };
          targetChecks = {
            bad = {
              on = "linked";
              run = { pkgs, ... }: fails "bad" { inherit pkgs; };
            };
            rawBad = {
              on = "linked";
              run = raw "raw-bad" "echo raw check ran; exit 1";
            };
            rawGood = {
              on = "linked";
              run = raw "raw-good" "echo raw check ran > $out";
            };
          };
        }).p;
      skipped = productOf {
        roots = {
          "p/bin/a" = root "a" true;
          "p/bin/b" = root "b" true;
        };
      };
      # One root built: `boom` runs and fails, and so does the raw stage; the
      # raw check runs its own builder.
      builtRoots = {
        "p/bin/a" = root "a" false;
        "p/bin/b" = root "b" true;
      };
      built = productOf { roots = builtRoots; };
      # Content addressing reaches a bare `derivation` too (evaluated only:
      # building it needs the `ca-derivations` feature).
      builtCa = productOf {
        roots = builtRoots;
        ca = true;
      };
      m = S.noBinariesMarker;
    in
    pkgs.runCommand "stages-no-binaries"
      {
        product = skipped;
        linked = skipped.stages.linked;
        debug = skipped.stages.splitDebug.debug;
        extra = skipped.stages.structured.extra;
        noSrc = skipped.checks.noSourceReferences;
        bad = skipped.checks.bad;
        rawStage = skipped.stages.rawStage;
        rawBad = skipped.checks.rawBad;
        builtBoom = pkgs.testers.testBuildFailure built.stages.boom;
        builtRawGood = built.checks.rawGood;
        caRaw =
          assert builtCa.stages.rawStage.drvAttrs.__contentAddressed;
          assert builtCa.checks.rawGood.drvAttrs.__contentAddressed;
          assert builtCa.stages.rawStage.drvAttrs.builder == "${pkgs.stdenv.shell}";
          "ok";
      }
      ''
        set -euo pipefail
        grep -qxF 'a: needs feature cli' $linked/${m}
        grep -qxF 'b: needs feature cli' $linked/${m}
        for d in $product $debug $extra $noSrc $bad $rawStage $rawBad; do
          cmp $linked/${m} $d/${m}
        done
        grep -q 'boom ran' $builtBoom/testBuildFailure.log
        grep -qxF 'raw check ran' $builtRawGood
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

  # wasmOpt accepts what rustc emits for wasm32 by default: a module using
  # memory.copy (bulk memory), which wasm-opt rejects without
  # --enable-bulk-memory (field trials: mtgac's Leptos UI).
  stages-wasm-opt-features =
    let
      module = pkgs.runCommand "bulk-memory-wasm" { nativeBuildInputs = [ pkgs.wasm-tools ]; } ''
        mkdir $out
        cat > m.wat <<'EOF'
        (module
          (memory (export "memory") 1)
          (func (export "copy") (param i32 i32 i32)
            (memory.copy (local.get 0) (local.get 1) (local.get 2))))
        EOF
        wasm-tools parse m.wat -o $out/m.wasm
      '';
      opt = H.wasmOpt (stageArgs module);
    in
    pkgs.runCommand "stages-wasm-opt-features" { nativeBuildInputs = [ pkgs.wasm-tools ]; } ''
      wasm-tools print ${opt}/m.wasm | grep -q memory.copy
      touch $out
    '';
}
