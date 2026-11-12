# Checks for lib/stages.nix and lib/stage-helpers (post-link stages),
# wired into the flake's `checks.<system>`. The "linked" inputs are built
# with plain stdenv (a C program) and rust-overlay (a wasm32 cdylib), not
# by the planner.
#
#   stages-eval         evaluation-time assertions: ordering from after/
#                       before, preset chains, removal with null, `install`
#                       and stages after it, error messages for cycles, missing and
#                       ambiguous references, CA attributes, helper options
#   stages-chain        three logging stages run in the computed order;
#                       every intermediate is addressable
#   stages-split-debug  Linux product of a C program (the `post-link` and
#                       `source-paths` fixture intents): gdb resolves source
#                       lines only with the debug output; a check on
#                       `linked` sees the unstripped bytes; the main output
#                       has no source reference and `debug` has one;
#                       noSourceReferences fails on an unsplit product,
#                       its message naming the docs, the narrowing and the
#                       removal under the check's own name
#   stages-after-install  a wrapProgram stage after `install`: no reference
#                       to an earlier stage's output, `debug` kept on Linux
#                       `split` and on msvc, a check on `install`
#   stages-elf-helpers  strip, strip --strip-all, patchelfRpath
#   stages-install      install layouts for unix (Linux, Apple), windows
#                       (msvc, MinGW), Cygwin and wasm inputs: root files
#                       by kind (a wasm cdylib to lib/, a wasm bin to bin/,
#                       a Cygwin DLL to bin/), other files by suffix,
#                       directories (bindgen's pkg/, share/) unchanged
#   stages-no-store-paths  noStorePaths names every store path in any
#                       file's bytes and how to remove the check, and
#                       passes once each is allowed
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
#   stages-build-script-path  buildScriptPath and the build-script lookups
#                       over stand-in runs (a `links` package, two versions
#                       of one package), with the runs listed as in IFD mode
#                       and through a `breakbulk-root.json` as in dynamic
#                       mode: the copies, an ambiguous package failing
#                       with its versions, a missing key or links name
#                       failing with what there is; options of both forms
#                       or of neither fail evaluation
#   stages-wasm-metadata  componentize's metadata: a revision read from a
#                       derivation, defaults from `product.package`, a
#                       field set to null left out; `cargoMetadata =
#                       false` gives `wasm-tools component new`'s bytes;
#                       wasmMetadata on a core module
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

  helperNames = lib.attrNames (lib.filterAttrs (_: H.isHelper) H);
  # Stage arguments for helpers evaluated, not built.
  helperArgs = {
    input = pkgs.emptyDirectory;
    product.name = "p";
    target = { };
    inherit pkgs;
  };

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
    # A replaced install keeps its default position.
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
          (has "  install  after: -; before: -; others run before it unless ordered after it" e)
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
    # A stage after `install`, one after that, and one that names neither
    # (before `install` by default).
    testAfterInstall = {
      expr = orderOf (
        S.merge [
          (S.chain [ "splitDebug" ])
          {
            wrap = {
              after = "install";
              run = dummy;
            };
            sign = {
              after = "wrap";
              run = dummy;
            };
            patch = {
              after = "splitDebug";
              run = dummy;
            };
          }
        ]
      );
      expected = [
        "splitDebug"
        "patch"
        "install"
        "wrap"
        "sign"
      ];
    };
    testBeforeAfterInstalled = {
      expr = orderOf {
        early = {
          before = "late";
          run = dummy;
        };
        late = {
          after = "install";
          run = dummy;
        };
      };
      expected = [
        "early"
        "install"
        "late"
      ];
    };
    # Stages after `install` follow the same total-order rule.
    testAfterInstallAmbiguous = {
      expr = has "nothing orders `a` and `b`" (errorOf {
        a = {
          after = "install";
          run = dummy;
        };
        b = {
          after = "install";
          run = dummy;
        };
      });
      expected = true;
    };
    testAfterInstallCycle = {
      expr = has "cycle among install, late" (errorOf {
        late = {
          after = "install";
          before = "install";
          run = dummy;
        };
      });
      expected = true;
    };
    # Without `install`, a constraint naming it is dropped.
    testAfterRemovedInstall = {
      expr = orderOf {
        late = {
          after = "install";
          run = dummy;
        };
        install = null;
      };
      expected = [ "late" ];
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
    testDebugAfterInstall = {
      expr = {
        order = helloWrapped.stageOrder;
        linux = helloWrapped.debug.drvPath == helloWrapped.stages.splitDebug.debug.drvPath;
        msvc = msvcSigned.debug.drvPath == msvcSigned.stages.install.debug.drvPath;
        msvcFinal = msvcSigned.drvPath == msvcSigned.stages.sign.drvPath;
      };
      expected = {
        order = [
          "splitDebug"
          "install"
          "wrap"
        ];
        linux = true;
        msvc = true;
        msvcFinal = true;
      };
    };
    # The buildScriptFiles check suggests a place before `install`, not
    # after the last stage.
    testBuildScriptFilesStanza = {
      expr =
        (H.buildScriptFilesIncluded {
          input = helloLinked;
          product = {
            name = "p";
            buildScriptFlags = [ ];
            stageOrder = [
              "splitDebug"
              "install"
              "wrap"
            ];
          };
          inherit pkgs;
        }).stanza;
      expected = "packages.p.stages.buildScriptFiles = { after = \"splitDebug\"; before = \"install\"; run = breakbulk.stageHelpers.buildScriptFiles { }; };";
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
      expr = lib.isFunction (H.wasmOpt { flags = [ "-O3" ]; });
      expected = true;
    };
    testHelperUnknownOption = {
      expr = (builtins.tryEval (H.wasmOpt { flag = [ "-O3" ]; })).success;
      expected = false;
    };
    # Options are checked when the stage is made, also those this use of
    # the helper does not read.
    testHelperWrongType = {
      expr = map (h: (builtins.tryEval (h helperArgs).drvPath).success) [
        (H.wasmOpt { flags = "-O3"; })
        (H.wasmOpt { flags = [ 3 ]; })
        (H.splitDebug { llvm = "llvm"; })
        (H.componentize { metadata.name = 3; })
        H.patchelfRpath
      ];
      expected = [
        false
        false
        false
        false
        false
      ];
    };
    # Configuring again sets the given options over the earlier ones.
    testHelperReconfigured = {
      expr =
        lib.hasInfix "wasm-opt -O1 \"$f\""
          (H.wasmOpt { flags = [ "-O1" ]; } { features = [ ]; } helperArgs).buildCommand;
      expected = true;
    };
    testHelperComponentizeMetadata = {
      expr =
        lib.hasInfix ''
          meta=()
          meta+=(--licenses MIT)
          meta+=(--name comp)
          meta+=(--processed-by 'breakbulk=0.1.0')
          meta+=(--x-custom a)
          meta+=(--x-custom b)
        ''
          (H.componentize {
            metadata = {
              name = "comp";
              processedBy.breakbulk = "0.1.0";
              licenses = "MIT";
              xCustom = [
                "a"
                "b"
              ];
            };
          } helperArgs).buildCommand;
      expected = true;
    };
    # Defaults from `product.package`: a field given wins, `null` leaves
    # one out, `cargoMetadata = false` adds none.
    testHelperMetadataDefaults =
      let
        args = helperArgs // {
          product = {
            name = "p";
            package = {
              name = "p";
              version = "1.2.3";
              authors = [
                "A"
                "B"
              ];
              description = "From the manifest";
              license = "MIT";
              repository = "https://example.com/p";
              edition = "2021";
            };
          };
        };
        metaOf = h: lib.filter (lib.hasPrefix "meta+=") (map lib.trim (lib.splitString "\n" (h args).buildCommand));
      in
      {
        expr = {
          defaults = metaOf H.wasmMetadata;
          given = metaOf (
            H.wasmMetadata {
              metadata = {
                name = "q";
                licenses = null;
              };
            }
          );
          off = metaOf (H.componentize { cargoMetadata = false; });
        };
        expected = {
          defaults = [
            "meta+=(--authors A,B)"
            "meta+=(--description 'From the manifest')"
            "meta+=(--licenses MIT)"
            "meta+=(--name p)"
            "meta+=(--source https://example.com/p)"
            "meta+=(--version 1.2.3)"
          ];
          given = [
            "meta+=(--authors A,B)"
            "meta+=(--description 'From the manifest')"
            "meta+=(--name q)"
            "meta+=(--source https://example.com/p)"
            "meta+=(--version 1.2.3)"
          ];
          off = [ ];
        };
      };
    # A derivation or a path is read at build time; a string naming a
    # store path stays a literal.
    testHelperMetadataFiles =
      let
        file = pkgs.writeText "rev" "abc\n";
        path = builtins.unsafeDiscardStringContext "${file}";
        cmd =
          (H.wasmMetadata {
            cargoMetadata = false;
            metadata = {
              revision = file;
              source = "${file}";
              processedBy.tool = file;
            };
          } helperArgs).buildCommand;
      in
      {
        expr = lib.filter (lib.hasPrefix "meta") (
          map lib.trim (
            lib.splitString "\n" (lib.replaceStrings [ path ] [ "FILE" ] (builtins.unsafeDiscardStringContext cmd))
          )
        );
        expected = [
          "metaRead() {"
          "metaValue=$(cat \"$1\"; echo x)"
          "metaValue=\${metaValue%x}"
          "metaValue=\${metaValue%$'\\n'}"
          "meta=()"
          "metaRead FILE"
          "meta+=(--processed-by 'tool='\"$metaValue\")"
          "metaRead FILE"
          "meta+=(--revision ''\"$metaValue\")"
          "meta+=(--source FILE)"
        ];
      };
    # Every helper the library exports declares a kind and describes
    # itself and each option (the generated reference lists them).
    testHelperDeclarations = {
      expr = lib.filter (
        n:
        let
          h = H.${n};
          opts = lib.optionAttrSetToDocList h.options;
        in
        !(
          lib.elem h.kind [
            "stage"
            "check"
          ]
          && h.description != ""
          && lib.all (o: o.internal || (o.description or null) != null && o.type != "unspecified") opts
        )
      ) helperNames;
      expected = [ ];
    };
    testHelperNames = {
      expr = lib.all (n: lib.elem n helperNames) [
        "bindgen"
        "install"
        "noSourceReferences"
      ];
      expected = true;
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
  # `sourcesOnly` runs the same helper under another name.
  helloUnsplit = S.mkProduct {
    name = "hello-unsplit";
    linked = helloLinked;
    stages = { };
    checks.sourcesOnly.run = H.noSourceReferences { toolchain = [ ]; };
    sourcePaths = [ helloSrc ];
    inherit pkgs;
  };

  closureOf = d: "${pkgs.closureInfo { rootPaths = [ d ]; }}/store-paths";

  # --- stages after install --------------------------------------------------

  # wrapProgram after `install`: the wrapper names only its own output.
  wrapStage =
    { input, pkgs, ... }:
    pkgs.runCommand "hello-wrapped" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      cp -R ${input} $out
      chmod -R u+w $out
      wrapProgram $out/bin/hello --set HELLO_WRAPPED 1
    '';
  helloWrapped = S.mkProduct {
    name = "hello-wrapped";
    linked = helloLinked;
    stages = S.chain [ "splitDebug" ] // {
      wrap = {
        after = "install";
        run = wrapStage;
      };
    };
    target.triple = "x86_64-unknown-linux-gnu";
    sourcePaths = [ helloSrc ];
    inherit pkgs;
    checks.installed = {
      on = "install";
      run =
        { input, pkgs, ... }:
        pkgs.runCommand "hello-installed" { } ''
          test -x ${input}/bin/hello
          test ! -e ${input}/bin/.hello-wrapped
          touch $out
        '';
    };
  };

  # An msvc product: `install` writes the PDB to its own `debug` output,
  # which a later `sign` stage without one keeps.
  msvcLinked = pkgs.runCommand "app-linked" {
    outputs = [
      "out"
      "debug"
    ];
  } ''
    mkdir $out $debug
    echo exe > $out/app.exe
    echo pdb > $debug/app.pdb
  '';
  msvcSigned = S.mkProduct {
    name = "app";
    linked = msvcLinked;
    stages.sign = {
      after = "install";
      run =
        { input, pkgs, ... }:
        pkgs.runCommand "app-signed" { } ''
          cp -R ${input} $out
          chmod -R u+w $out
          echo signed >> $out/bin/app.exe
        '';
    };
    target.triple = "x86_64-pc-windows-msvc";
    inherit pkgs;
  };

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
    # As mkProducts gives it: install places the root's file by kind.
    info.rootFiles."adder.wasm" = "cdylib";
    inherit pkgs;
  };

  # --- wasm metadata -----------------------------------------------------------

  # A revision computed in a derivation, as a stamp would compute one.
  revisionFile = pkgs.runCommand "adder-revision" { } "printf 'tree:abc;guest:def\\n' > $out";
  # The adder as a product of a package with these manifest fields.
  withPackage =
    stages:
    S.mkProduct {
      name = "adder";
      linked = addLinked;
      inherit stages pkgs;
      target.triple = "wasm32-unknown-unknown";
      info = {
        rootFiles."adder.wasm" = "cdylib";
        package = {
          name = "adder";
          version = "0.3.0";
          authors = [
            "A. Author"
            "B. Author"
          ];
          description = "Adds two numbers";
          license = "MIT OR Apache-2.0";
          repository = "https://example.com/adder";
          homepage = "https://example.com/";
        };
      };
    };
  componentized =
    componentizeRun:
    withPackage (
      S.merge [
        S.defaultStages.wasmComponent
        { componentize.run = componentizeRun; }
      ]
    );
  metaDefaults = componentized (
    H.componentize {
      metadata = {
        revision = revisionFile;
        homepage = null;
      };
    }
  );
  metaOff = componentized (H.componentize { cargoMetadata = false; });
  # A core module, not componentized.
  metaCore = withPackage {
    meta = {
      after = "linked";
      run = H.wasmMetadata {
        metadata = {
          name = "adder-core";
          revision = revisionFile;
        };
      };
    };
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

  # `rootFiles` (file name to root kind) as mkProducts gives it; a file
  # name with a `/` is created in that directory.
  installOf' =
    triple: rootFiles: files:
    H.install {
      input = pkgs.runCommand "install-in-${triple}" { } ''
        mkdir -p $out/share/doc
        cd $out
        echo doc > share/doc/README
        ${lib.concatMapStrings (f: ''
          mkdir -p "$(dirname ${f.name})"
          echo ${f.name} > ${f.name}
          ${lib.optionalString (f.x or false) "chmod +x ${f.name}"}
        '') files}
      '';
      product = {
        name = "inst";
        inherit rootFiles;
      };
      target = { inherit triple; };
      inherit pkgs;
    };
  installOf = triple: installOf' triple { };
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
  # A cdylib and a bin with the same suffix, placed by root kind; bindgen's
  # pkg/ and an earlier stage's share/ kept as they are.
  installWasm =
    installOf' "wasm32-unknown-unknown"
      {
        "ui.wasm" = "cdylib";
        "cli.wasm" = "bin";
      }
      [
        { name = "ui.wasm"; }
        { name = "cli.wasm"; }
        { name = "pkg/ui.js"; }
        { name = "pkg/ui_bg.wasm"; }
      ];
  # Cygwin's DLL beside the executable, as on Windows, though it is not
  # `isWindows`.
  installCygwin =
    installOf' "x86_64-pc-cygwin"
      {
        "foo.dll" = "cdylib";
        "app.exe" = "bin";
      }
      [
        { name = "foo.dll"; }
        { name = "app.exe"; }
      ];
  # A bin and a cdylib of one package, by root kind.
  installRoots =
    installOf' "x86_64-unknown-linux-gnu"
      {
        app = "bin";
        "libapp.so" = "cdylib";
        "libapp.a" = "staticlib";
      }
      [
        { name = "app"; }
        { name = "libapp.so"; }
        { name = "libapp.a"; }
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
        renamedFails = pkgs.testers.testBuildFailure helloUnsplit.checks.sourcesOnly;
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

        # noSourceReferences fails on an unsplit product, naming the source,
        # the docs section, how to narrow the check and how to remove it.
        log=$unsplitFails/testBuildFailure.log
        cat $log
        test "$(cat $unsplitFails/testBuildFailure.exit)" = 1
        grep -q 'references source ${helloSrc}' $log
        grep -qF '"Source paths and debug information"' $log
        grep -qF 'explanation/products.html#source-paths-and-debug-information' $log
        if grep -qF 'design' $log; then echo "message names the design document"; exit 1; fi
        grep -qxF 'Check sources only: packages.hello-unsplit.checks.noSourceReferences.run = breakbulk.stageHelpers.noSourceReferences { toolchain = [ ]; };' $log
        test "$(tail -n1 $log)" = 'or, when hello-unsplit may reference them: packages.hello-unsplit.checks.noSourceReferences = null;'
        # Under another name, the message names that name.
        log=$renamedFails/testBuildFailure.log
        grep -qxF 'Check sources only: packages.hello-unsplit.checks.sourcesOnly.run = breakbulk.stageHelpers.noSourceReferences { toolchain = [ ]; };' $log
        test "$(tail -n1 $log)" = 'or, when hello-unsplit may reference them: packages.hello-unsplit.checks.sourcesOnly = null;'
        touch $out
      '';

  # A stage after `install`: the wrapper's closure holds no earlier
  # stage's output, the build ID and debuglink survive wrapping, `debug`
  # is splitDebug's, and a check on `install` sees the installed layout.
  # On msvc a signing stage after `install` keeps install's PDB.
  stages-after-install =
    pkgs.runCommand "stages-after-install"
      {
        nativeBuildInputs = [ pkgs.binutils-unwrapped-all-targets ];
        checks = lib.attrValues helloWrapped.checks;
      }
      ''
        set -euo pipefail
        p=${helloWrapped}
        test "$($p/bin/hello)" = "hello 42"
        grep -qF "$p/bin/.hello-wrapped" $p/bin/hello
        for d in ${helloWrapped.stages.install} ${helloWrapped.stages.splitDebug} ${helloLinked}; do
          if grep -qxF $d ${closureOf helloWrapped}; then
            echo "the wrapped product references $d"; exit 1
          fi
        done

        id=$(readelf -n $p/bin/.hello-wrapped | sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p')
        test -f ${helloWrapped.debug}/lib/debug/.build-id/''${id:0:2}/''${id:2}.debug
        readelf --string-dump=.gnu_debuglink $p/bin/.hello-wrapped | grep -q "''${id:2}.debug"

        grep -qx 'exe' ${msvcSigned}/bin/app.exe
        grep -qx 'signed' ${msvcSigned}/bin/app.exe
        test "$(cat ${msvcSigned.debug}/bin/app.pdb)" = pdb
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
    test -f $a/lib/ui.wasm; test -f $a/bin/cli.wasm
    test -f $a/pkg/ui.js; test -f $a/pkg/ui_bg.wasm; test -f $a/share/doc/README
    c=${installCygwin}; r=${installRoots}
    test -f $c/bin/foo.dll; test -f $c/bin/app.exe
    test -f $r/bin/app; test -f $r/lib/libapp.so; test -f $r/lib/libapp.a
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
        test "$(tail -n1 $log)" = 'or, when p may name them: packages.p.checks.noStorePaths = null;'
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
        before=$(stat -c %s ${wasmBrowser.stages.bindgen}/pkg/wasm_hello_bg.wasm)
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
        c=${component}/lib/adder.wasm
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

  stages-wasm-metadata =
    pkgs.runCommand "stages-wasm-metadata"
      {
        nativeBuildInputs = [
          pkgs.wasm-tools
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        # The outermost component's or module's field, or "null".
        field() { wasm-tools metadata show --json "$1" | jq -r "(.component.metadata // .module).$2"; }
        expect() {
          local got
          got=$(field "$1" "$2")
          if [ "$got" != "$3" ]; then
            echo "$1: $2 is '$got', not '$3'" >&2
            exit 1
          fi
        }

        c=${metaDefaults}/lib/adder.wasm
        wasm-tools print $c | head -n1 | grep -q '^(component'
        wasm-tools metadata show $c
        # From the derivation, without its trailing newline.
        expect $c revision 'tree:abc;guest:def'
        # From the package's manifest.
        expect $c name adder
        expect $c description 'Adds two numbers'
        expect $c licenses 'MIT OR Apache-2.0'
        expect $c source https://example.com/adder
        expect $c authors 'A. Author,B. Author'
        expect $c version 0.3.0
        # Set to null: left out.
        expect $c homepage null

        # cargoMetadata = false and no metadata: wasm-tools component new's
        # bytes, as before metadata defaults.
        wasm-tools component new ${metaOff.stages.wasmOpt}/adder.wasm -o plain.wasm
        cmp plain.wasm ${metaOff}/lib/adder.wasm

        # A core module.
        m=${metaCore}/lib/adder.wasm
        wasm-tools print $m | head -n1 | grep -q '^(module'
        wasm-tools metadata show $m
        expect $m name adder-core
        expect $m revision 'tree:abc;guest:def'
        expect $m description 'Adds two numbers'
        expect $m homepage https://example.com/
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

  # Stand-in build-script runs: an `out` holding the OUT_DIR at a nested
  # path, as a run's does, and a `flags` with its `metadata.json`.
  stages-build-script-path =
    let
      fakeRun =
        {
          package,
          version,
          links ? null,
          # `[ key value ]` pairs; `@OUT_DIR@` stands for the OUT_DIR.
          metadata ? [ ],
          script,
        }:
        pkgs.runCommand "${package}-${version}-build-run"
          {
            outputs = [
              "out"
              "flags"
            ];
            nativeBuildInputs = [ pkgs.jq ];
            runInfo = builtins.toJSON {
              inherit
                package
                version
                links
                metadata
                ;
            };
          }
          ''
            OUT_DIR=$out/release/build/${package}-0123/out
            mkdir -p "$OUT_DIR" $flags
            ${script}
            jq -c --arg o "$OUT_DIR" '
              .metadata |= map(map(sub("@OUT_DIR@"; $o)))
              | .out = $o
              | if .links == null then del(.links) else . end' <<< "$runInfo" > $flags/metadata.json
          '';
      hdr = fakeRun {
        package = "hdr-sys";
        version = "0.1.0";
        links = "hdr";
        metadata = [
          [
            "include"
            "/nowhere"
          ]
          [
            "include"
            "@OUT_DIR@/include"
          ]
          [
            "version"
            "3"
          ]
        ];
        script = ''
          mkdir -p "$OUT_DIR/include"
          echo '#define HDR 3' > "$OUT_DIR/include/hdr.h"
        '';
      };
      dup =
        version:
        fakeRun {
          package = "dup";
          inherit version;
          script = "echo ${version} > $OUT_DIR/v.txt";
        };
      runs = [
        hdr
        (dup "0.1.0")
        (dup "0.2.0")
      ];
      ifdFlags = map (r: r.flags) runs;
      rootInfo = pkgs.writeText "breakbulk-root.json" (
        builtins.toJSON { buildScriptFlags = map (r: "${r.flags}") runs; }
      );
      productOf =
        buildScriptFlags: stages:
        S.mkProduct {
          name = "app";
          linked = pkgs.runCommand "app-linked" { } "mkdir $out; echo app > $out/app";
          inherit pkgs stages;
          info = { inherit buildScriptFlags; };
          defaultChecks = false;
        };
      # A stage reading the runs with the lookups, as a user's would.
      lookups =
        {
          input,
          product,
          pkgs,
          ...
        }@args:
        pkgs.runCommand "app-lookups" { } ''
          set -euo pipefail
          ${H.buildScriptLookups args}
          cp -RL ${input} $out
          chmod -R u+w $out
          dir=$(buildScriptOutDir dup 0.2.0)
          cp "$dir/v.txt" $out/dup-v.txt
          buildScriptMetadata hdr version > $out/hdr-version
          buildScriptRuns > $out/runs
        '';
      stages = {
        headers = {
          before = "install";
          run = H.buildScriptPath {
            links = "hdr";
            key = "include";
            to = "include";
          };
        };
        dupData = {
          after = "headers";
          before = "install";
          run = H.buildScriptPath {
            package = "dup";
            version = "0.1.0";
            from = "v.txt";
            to = "share/dup/v.txt";
          };
        };
        lookups = {
          after = "install";
          run = lookups;
        };
      };
      ifd = productOf ifdFlags stages;
      dynamic = productOf { rootInfo = [ "${rootInfo}" ]; } stages;
      failing =
        name: run:
        pkgs.testers.testBuildFailure (
          (productOf ifdFlags {
            ${name} = {
              before = "install";
              inherit run;
            };
          }).stages.${name}
        );
      evalFails =
        opts:
        !(builtins.tryEval
          (builtins.seq (H.buildScriptPath opts {
            input = pkgs.emptyDirectory;
            product = {
              name = "app";
              buildScriptFlags = [ ];
            };
            inherit pkgs;
          }).drvPath null
          )
        ).success;
    in
    assert lib.assertMsg (evalFails {
      links = "hdr";
      to = "include";
    }) "buildScriptPath: `links` without `key` evaluates";
    assert lib.assertMsg (evalFails {
      links = "hdr";
      key = "include";
      from = "include";
      to = "include";
    }) "buildScriptPath: options of both forms evaluate";
    assert lib.assertMsg (evalFails {
      package = "dup";
      to = "x";
    }) "buildScriptPath: `package` without `from` evaluates";
    assert lib.assertMsg (evalFails {
      package = "dup";
      from = "v.txt";
      to = "../x";
    }) "buildScriptPath: a `to` outside the product evaluates";
    pkgs.runCommand "stages-build-script-path"
      {
        ambiguous = failing "dupData" (
          H.buildScriptPath {
            package = "dup";
            from = "v.txt";
            to = "v.txt";
          }
        );
        noKey = failing "headers" (
          H.buildScriptPath {
            links = "hdr";
            key = "lib";
            to = "lib";
          }
        );
        noLinks = failing "headers" (
          H.buildScriptPath {
            links = "z";
            key = "include";
            to = "include";
          }
        );
        noPackage = failing "dupData" (
          H.buildScriptPath {
            package = "nope";
            from = ".";
            to = "x";
          }
        );
        taken = failing "dupData" (
          H.buildScriptPath {
            package = "dup";
            version = "0.2.0";
            from = "v.txt";
            to = "app";
          }
        );
      }
      ''
        set -euo pipefail
        for p in ${ifd} ${dynamic}; do
          grep -qF '#define HDR 3' $p/include/hdr.h
          [ "$(cat $p/share/dup/v.txt)" = 0.1.0 ]
          [ "$(cat $p/dup-v.txt)" = 0.2.0 ]
          [ "$(cat $p/hdr-version)" = 3 ]
          [ "$(wc -l < $p/runs)" = 3 ]
          [ -f $p/app ]
        done
        cmp ${ifd}/include/hdr.h ${dynamic}/include/hdr.h
        grep -qF 'app depends on several build-script runs of dup: dup 0.1.0 (OUT_DIR ' $ambiguous/testBuildFailure.log
        grep -qF 'dup 0.2.0 (OUT_DIR ' $ambiguous/testBuildFailure.log
        grep -qF 'name one by its version' $ambiguous/testBuildFailure.log
        grep -qF 'the build script of hdr-sys 0.1.0 (links = "hdr") printed no metadata key "lib"; its keys: include, version' $noKey/testBuildFailure.log
        grep -qF 'app depends on no build-script run with links = "z"; the links names below it: hdr' $noLinks/testBuildFailure.log
        grep -qF 'app depends on no build-script run of nope; the runs below it are of: dup 0.1.0, dup 0.2.0, hdr-sys 0.1.0' $noPackage/testBuildFailure.log
        grep -qF 'buildScriptPath: app already has app' $taken/testBuildFailure.log
        touch $out
      '';
}
