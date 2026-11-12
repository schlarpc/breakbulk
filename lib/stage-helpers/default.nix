# Stage and check helpers ("Stage helpers" in
# docs/src/explanation/internals/products.md).
#
# Every helper is usable two ways:
#
#   run = helpers.wasmOpt;                          # defaults
#   run = helpers.wasmOpt { flags = [ "-O3" ]; };   # configured
#
# A helper is a function of one attribute set. Called with the stage
# arguments (`{ input, product, target, pkgs }`, recognised by `input`) it
# builds the stage; called with anything else it returns the same helper
# with those options set. Options are module-system declarations
# (`mkOption`), checked with `lib.evalModules`; their descriptions are
# docs/src/reference/stage-helpers.md (`nix run .#update-docs-options`).
#
# A new helper:
#
#   myHelper = mkHelper {
#     name = "myHelper";
#     description = "What the stage does (Markdown).";
#     kind = "stage";            # or "check": used as `checks.<name>.run`
#     options.level = mkOption { type = types.int; default = 1; description = "…"; };
#   } (cfg: { input, product, pkgs, ... }: <derivation>);
#
# and its name in the attribute set at the end of this file.
#
# Conventions shared by all helpers:
# - `input` is a derivation whose output is a directory (the raw link output
#   or the previous stage). Symlinks in it are followed, so the `linked`
#   stage may be a symlink to a unit output. A plain-file input is accepted
#   and treated as a directory holding that one file.
# - The result is a `runCommand` derivation (so mkProduct can make it
#   content-addressed with overrideAttrs), named `<product>-<helper>`.
# - Nothing runs stdenv's fixup phase: no implicit strip, patchelf or
#   rpath shrinking happens anywhere.
# - Tools default to nixpkgs packages from the stage's `pkgs`; each helper
#   that uses one takes an option to replace it.
{
  lib,
  wasmBindgen,
  targetTraits,
}:
let
  inherit (lib)
    attrNames
    concatStringsSep
    escapeShellArg
    escapeShellArgs
    isAttrs
    isDerivation
    mapAttrsToList
    mkOption
    literalExpression
    types
    ;

  # A helper is an attribute set that can be called (`__functor`), so that
  # it carries its declaration: `name`, `description`, `kind` and
  # `options`, the evaluated option tree (as a module system's `options`),
  # from which the reference page is generated.
  mkHelper =
    {
      name,
      description,
      kind ? "stage",
      options ? { },
    }:
    impl:
    let
      known = attrNames options;
      # The options sit under the helper's name, so that the module
      # system's errors name `<helper>.<option>`.
      evalWith =
        given:
        lib.evalModules {
          modules = [
            { options.${name} = options; }
            {
              _file = "breakbulk.stageHelpers.${name} { … }";
              config.${name} = given;
            }
          ];
        };
      declared = (evalWith { }).options.${name};
      make =
        given:
        let
          cfg = (evalWith given).config.${name};
          # Every option forced, so that a wrong type fails even when this
          # use of the helper does not read the option.
          checked = lib.foldl' (acc: n: builtins.seq cfg.${n} acc) cfg known;
        in
        {
          inherit name description kind;
          options = declared;
          __functor =
            _: arg:
            if arg ? input then
              impl checked arg
            else
              let
                unknown = attrNames (removeAttrs arg known);
              in
              if unknown != [ ] then
                throw "breakbulk stage helper `${name}`: unknown option(s) ${concatStringsSep ", " unknown}; known options: ${
                  if known == [ ] then "(none)" else concatStringsSep ", " known
                }"
              else
                make (given // arg);
        };
    in
    assert lib.assertMsg (lib.elem kind [
      "stage"
      "check"
    ]) "breakbulk stage helper `${name}`: kind must be \"stage\" or \"check\", not ${builtins.toJSON kind}";
    make { };

  # An option that replaces the nixpkgs package a helper runs.
  toolOption =
    attr:
    mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "The package to run instead of `${attr}` from the stage's `pkgs`.";
    };
  toolOf =
    cfgValue: pkgs: attr:
    if cfgValue != null then cfgValue else pkgs.${attr};

  # A store path as a string, a path or a derivation. `str` comes first:
  # `package` would turn a store-path string into a derivation.
  storePathType = types.oneOf [
    types.str
    types.path
    types.package
  ];

  # The traits of a stage's target (lib/target-traits.nix): `target.traits`
  # when the product has them (mkRepository passes them, with the user's
  # `targets.<triple>.traits`), else the built-in ones of `target.triple`,
  # else of the platform the stage's `pkgs` build for.
  traitsOf =
    target: pkgs:
    target.traits or (targetTraits.resolve {
      triple = target.triple or (targetTraits.nativeTriple pkgs);
    });

  # How `install` and `placeDebug` lay files out for a platform.
  # Copy the input into "$1" (created), following symlinks, writable.
  copyIn = input: ''
    copyIn() {
      mkdir -p "$1"
      if [ -d ${input} ]; then
        cp -RL --no-preserve=ownership ${input}/. "$1"/
      else
        cp -L ${input} "$1/$(basename ${input} | cut -d- -f2-)"
      fi
      chmod -R u+w "$1"
    }
  '';

  # The debuginfo side files of the product's link units
  # (`.pdb` on msvc, `.dwp`/`.dwo` with `split-debuginfo`), as the `linked`
  # stage's `debug` output holds them, go into a stage's `debug` output in
  # the install layout: next to where their binary lands (Windows: bin/;
  # elsewhere `*.so.dwp` under lib/, the rest under bin/).
  # `product.linkedDebug` is that output, when the product has one.
  placeDebugFn = product: target: pkgs: ''
    placeDebug() {
      ${
        if (product.linkedDebug or null) == null then
          "return 0"
        else
          ''
            local f b d
            for f in ${product.linkedDebug}/*; do
              [ -e "$f" ] || continue
              b=''${f##*/}
              case "${if (traitsOf target pkgs).isWindows then "windows" else "unix"}:$b" in
                windows:*) d=bin ;;
                unix:*.so.dwp|unix:*.so.*.dwp) d=lib ;;
                *) d=bin ;;
              esac
              mkdir -p "$1/$d"
              cp -L "$f" "$1/$d/$b"
              chmod u+w "$1/$d/$b"
            done
          ''
      }
    }
  '';

  isElfFn = ''
    isElf() { [ "$(head -c4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; }
  '';

  stageName = product: helper: "${product.name}-${helper}";

  binutilsOf = cfg: pkgs: toolOf cfg.binutils pkgs "binutils-unwrapped-all-targets";

  # ---------------------------------------------------------------------
  # ELF

  splitDebug = mkHelper {
    name = "splitDebug";
    description = ''
      Moves the debug information of every ELF file into the stage's
      `debug` output, at `lib/debug/.build-id/<xx>/<rest>.debug` (from
      the file's GNU build ID), where gdb and debuginfod look for it.
      The file keeps its symbol table and gets a `.gnu_debuglink`.
      A file without debug information is left as it is; one with debug
      information but no build ID fails the stage.

      The `.dwo` files a binary names (`split-debuginfo = "unpacked"`)
      are packed into `<binary>.dwp` with `llvm-dwp`; a `<binary>.dwp`
      (`"packed"`) moves next to the `.debug` file, where gdb finds it,
      with a symlink at its place in the install layout.
      `targets.<triple>.debugInfo = "split"` inserts this stage.
    '';
    options = {
      binutils = toolOption "binutils-unwrapped-all-targets";
      llvm = toolOption "llvm";
    };
  } (
    cfg:
    {
      input,
      product,
      pkgs,
      target ? { },
      ...
    }:
    pkgs.runCommand (stageName product "splitDebug")
      {
        outputs = [
          "out"
          "debug"
        ];
        nativeBuildInputs = [
          (binutilsOf cfg pkgs)
          (toolOf cfg.llvm pkgs "llvm")
        ];
      }
      ''
        set -euo pipefail
        ${copyIn input}
        ${isElfFn}
        ${placeDebugFn product target pkgs}
        copyIn "$out"
        mkdir -p "$debug"
        placeDebug "$debug"
        find "$out" -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d "" f; do
          isElf "$f" || continue
          if ! readelf -S -W "$f" | grep ' \.debug_info ' >/dev/null; then
            echo "splitDebug: ''${f#$out/}: no debug info, left unchanged"
            continue
          fi
          id=$(readelf -n "$f" | sed -n 's/.*Build ID: \([0-9a-f]*\).*/\1/p' | head -n1)
          if [ "''${#id}" -lt 3 ]; then
            echo "splitDebug: ''${f#$out/} has debug info but no GNU build ID; link it with --build-id (breakbulk's presets pass a content-derived one)" >&2
            exit 1
          fi
          dir="$debug/lib/debug/.build-id/''${id:0:2}"
          dbg="$dir/''${id:2}.debug"
          if [ -e "$dbg" ]; then
            echo "splitDebug: two files have build ID $id" >&2
            exit 1
          fi
          mkdir -p "$dir"
          echo "splitDebug: ''${f#$out/} (build ID $id)"
          objcopy --only-keep-debug "$f" "$dbg"
          objcopy --strip-debug "$f"
          objcopy --add-gnu-debuglink="$dbg" "$f"
          b=''${f##*/}
          # With split-debuginfo = "unpacked", the binary's skeleton units
          # name their `.dwo` files (its own and its libraries', decision
          # 126) by rustc's absolute build path, which gdb opens as given
          # and nowhere else (gdb 17.2, gdb/dwarf2/read.c, open_dwo_file).
          # llvm-dwp packs the ones it names into `<binary>.dwp`, which
          # gdb finds as below. Not binutils' dwp: it reads only DWARF 4's
          # DW_AT_GNU_dwo_id, so from DWARF 5 units it writes a .dwp with
          # no units in it, and succeeds.
          dwos=()
          while IFS= read -r n; do
            n=''${n##*/}
            for d in bin lib; do
              if [ -f "$debug/$d/$n" ]; then
                dwos+=("$debug/$d/$n")
                break
              fi
            done
          done < <(readelf --debug-dump=info,no-follow-links --dwarf-depth=1 "$dbg" 2>/dev/null | sed -n 's/^.*DW_AT_\(GNU_\)\{0,1\}dwo_name *: .*: //p' | LC_ALL=C sort -u)
          if [ ''${#dwos[@]} -gt 0 ] && [ ! -e "$debug/bin/$b.dwp" ] && [ ! -e "$debug/lib/$b.dwp" ]; then
            case "$b" in
              *.so|*.so.*) d=lib ;;
              *) d=bin ;;
            esac
            echo "splitDebug: ''${f#$out/}: packing ''${#dwos[@]} .dwo files into $b.dwp"
            mkdir -p "$debug/$d"
            llvm-dwp -o "$debug/$d/$b.dwp" "''${dwos[@]}"
          fi
          # With split-debuginfo = "packed", the DWARF objects are in
          # `<binary>.dwp`. gdb looks for it next to the separate debug file
          # it found, under the binary's name (gdb 17.2,
          # gdb/dwarf2/read.c, open_and_init_dwp_file), so it moves there;
          # its install-layout place keeps a relative symlink.
          for d in bin lib; do
            if [ -f "$debug/$d/$b.dwp" ] && [ ! -L "$debug/$d/$b.dwp" ]; then
              mv "$debug/$d/$b.dwp" "$dir/$b.dwp"
              ln -s "../lib/debug/.build-id/''${id:0:2}/$b.dwp" "$debug/$d/$b.dwp"
            fi
          done
        done
        # The `.dwo` files are in the `.dwp` files now, or no binary names
        # them (an rlib member the link left out); gdb reads neither
        # through their absolute names.
        find "$debug" -name '*.dwo' -type f -delete
      ''
  );

  strip =
    mkHelper
      {
        name = "strip";
        description = ''
          Runs `strip` on every ELF file: `--strip-debug`, or
          `--strip-all` with `all`. `targets.<triple>.debugInfo = "strip"`
          inserts this stage.
        '';
        options = {
          all = mkOption {
            type = types.bool;
            default = false;
            description = "Also remove the symbol tables (`--strip-all`), not only the debug information.";
          };
          binutils = toolOption "binutils-unwrapped-all-targets";
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        pkgs.runCommand (stageName product "strip") { nativeBuildInputs = [ (binutilsOf cfg pkgs) ]; } ''
          set -euo pipefail
          ${copyIn input}
          ${isElfFn}
          copyIn "$out"
          find "$out" -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d "" f; do
            isElf "$f" || continue
            strip ${if cfg.all then "--strip-all" else "--strip-debug"} "$f"
          done
        ''
      );

  patchelfRpath =
    mkHelper
      {
        name = "patchelfRpath";
        description = ''
          Adds run paths to every dynamically linked ELF file, so that it
          finds shared libraries loaded at run time (`dlopen`, or a
          library a build script placed next to it). Nothing shrinks the
          run paths afterwards.
        '';
        options = {
          libs = mkOption {
            type = types.nonEmptyListOf storePathType;
            example = literalExpression "[ pkgs.vulkan-loader \"$ORIGIN/../lib\" ]";
            description = ''
              The run paths to add, in order. A package or a path adds its
              `lib` directory; a string is added as it is.
            '';
          };
          patchelf = toolOption "patchelf";
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        let
          dirOf' = l: if isDerivation l || builtins.isPath l then "${l}/lib" else toString l;
          rpath = concatStringsSep ":" (map dirOf' cfg.libs);
        in
        pkgs.runCommand (stageName product "patchelfRpath")
          { nativeBuildInputs = [ (toolOf cfg.patchelf pkgs "patchelf") ]; }
          ''
            set -euo pipefail
            ${copyIn input}
            ${isElfFn}
            copyIn "$out"
            find "$out" -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d "" f; do
              isElf "$f" || continue
              # Static executables and objects have no dynamic section.
              patchelf --print-rpath "$f" >/dev/null 2>&1 || continue
              echo "patchelfRpath: ''${f#$out/}"
              patchelf --add-rpath ${escapeShellArg rpath} "$f"
            done
          ''
      );

  # ---------------------------------------------------------------------
  # wasm

  # The single core module in a stage directory.
  oneWasm = helper: ''
    mapfile -d "" wasms < <(find "$work" -type f -name '*.wasm' -print0 | LC_ALL=C sort -z)
    if [ "''${#wasms[@]}" -ne 1 ]; then
      echo "${helper}: expected exactly one .wasm file in the input, found ''${#wasms[@]}" >&2
      exit 1
    fi
    wasm="''${wasms[0]}"
  '';

  bindgen =
    mkHelper
      {
        name = "bindgen";
        description = ''
          Runs `wasm-bindgen` on the input's single `.wasm` file and
          writes its JavaScript glue and processed module to `pkg/`,
          which `install` keeps. The `wasmWeb` preset's first stage.
        '';
        options = {
          target = mkOption {
            type = types.str;
            default = "web";
            example = "nodejs";
            description = ''
              wasm-bindgen's `--target`: the kind of JavaScript to
              generate (`web`, `bundler`, `nodejs`, `deno`,
              `no-modules`, `module`, `experimental-nodejs-module`).
            '';
          };
          wasmBindgen = mkOption {
            type = types.nullOr types.package;
            default = null;
            example = literalExpression "pkgs.wasm-bindgen-cli_0_2_100";
            description = ''
              The wasm-bindgen CLI. It must be the version of the
              `wasm-bindgen` crate the module was built with.

              `null` finds it from the product's Cargo.lock
              (`product.lockfile`, or `product.lockEntries` for a
              product made with `mkProduct` that passes parsed entries):

              1. The version, X.Y.Z, is the lockfile's `wasm-bindgen`
                 package from a registry. Evaluation fails when the
                 lockfile has none, several versions, or one from git or
                 a path.
              2. nixpkgs' `wasm-bindgen-cli_X_Y_Z` from the stage's
                 `pkgs`, when it has that attribute.
              3. Otherwise wasm-bindgen-cli X.Y.Z from crates.io, built
                 with the stage's `pkgs.rustPlatform`, when breakbulk's
                 table `lib/wasm-bindgen-hashes.nix` has its hashes.
              4. Otherwise evaluation fails, naming the version. Pass
                 the CLI here, for example
                 `breakbulk.wasmBindgen.forVersion { inherit pkgs;
                 version = "X.Y.Z"; hashes."X.Y.Z" = { hash = …;
                 cargoHash = …; }; }`.
            '';
          };
          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [ ];
            example = [ "--no-typescript" ];
            description = "More arguments for `wasm-bindgen`, before the input file.";
          };
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        let
          cli =
            if cfg.wasmBindgen != null then
              cfg.wasmBindgen
            else if product ? lockfile then
              wasmBindgen.forLockfile {
                inherit pkgs;
                inherit (product) lockfile;
              }
            else if product ? lockEntries then
              wasmBindgen.forLockfile {
                inherit pkgs;
                entries = product.lockEntries;
              }
            else
              throw "breakbulk stage helper `bindgen` (product `${product.name}`): no wasm-bindgen CLI; the product carries no `lockfile` or `lockEntries` to match it from, so pass `bindgen { wasmBindgen = …; }`";
        in
        pkgs.runCommand (stageName product "bindgen") { nativeBuildInputs = [ cli ]; } ''
          set -euo pipefail
          ${copyIn input}
          work=$TMPDIR/in
          copyIn "$work"
          ${oneWasm "bindgen"}
          # pkg/: wasm-bindgen's layout, which install keeps.
          mkdir -p "$out/pkg"
          wasm-bindgen --target ${escapeShellArg cfg.target} --out-dir "$out/pkg" \
            ${escapeShellArgs cfg.extraArgs} "$wasm"
        ''
      );

  wasmOpt =
    mkHelper
      {
        name = "wasmOpt";
        description = ''
          Runs binaryen's `wasm-opt` on every `.wasm` file, in place. In
          the `wasmWeb` and `wasmComponent` presets.
        '';
        options = {
          flags = mkOption {
            type = types.listOf types.str;
            default = [ "-Oz" ];
            example = [ "-O3" ];
            description = "The optimisation arguments for `wasm-opt`.";
          };
          features = mkOption {
            type = types.listOf types.str;
            default = [
              "bulk-memory"
              "multivalue"
              "mutable-globals"
              "nontrapping-float-to-int"
              "reference-types"
              "sign-ext"
            ];
            description = ''
              The wasm features `wasm-opt` may assume, each passed as
              `--enable-<feature>`. The default is what rustc enables on
              `wasm32-unknown-unknown` since 1.87. wasm-opt's own default
              is the MVP, which rejects a Rust module that uses
              `memory.copy`.
            '';
          };
          binaryen = toolOption "binaryen";
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        pkgs.runCommand (stageName product "wasmOpt")
          { nativeBuildInputs = [ (toolOf cfg.binaryen pkgs "binaryen") ]; }
          ''
            set -euo pipefail
            ${copyIn input}
            copyIn "$out"
            find "$out" -type f -name '*.wasm' -print0 | LC_ALL=C sort -z | while IFS= read -r -d "" f; do
              echo "wasmOpt: ''${f#$out/}"
              wasm-opt ${escapeShellArgs (cfg.flags ++ map (f: "--enable-${f}") cfg.features)} "$f" -o "$f.opt"
              mv "$f.opt" "$f"
            done
          ''
      );

  # `metadata` keys map to `wasm-tools metadata add` flags: strings and lists
  # of strings become `--<kebab-key> value` (once per value); attribute sets
  # (for `language`, `processedBy`, `sdk`) become `NAME=VERSION` values.
  metadataArgs =
    metadata:
    lib.concatLists (
      mapAttrsToList (
        k: v:
        let
          flag =
            "--"
            + lib.concatMapStrings (c: if lib.toLower c != c then "-" + lib.toLower c else c) (
              lib.stringToCharacters k
            );
          values =
            if isAttrs v then
              mapAttrsToList (n: ver: "${n}=${ver}") v
            else if builtins.isList v then
              v
            else
              [ (toString v) ];
        in
        lib.concatMap (x: [
          flag
          x
        ]) values
      ) (lib.filterAttrs (k: v: k != "_module" && v != null) metadata)
    );

  # A `metadata` field that `wasm-tools metadata add` writes as a custom
  # section of one string.
  metadataString =
    what:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "${what} `null` adds none.";
    };
  # A producers-section field: tool names to versions.
  metadataProducers =
    what: example:
    mkOption {
      type = types.attrsOf types.str;
      default = { };
      inherit example;
      description = "${what}, by name, as `NAME=VERSION` in the producers section.";
    };

  componentize =
    mkHelper
      {
        name = "componentize";
        description = ''
          Makes a WebAssembly component from the input's single core
          module with `wasm-tools component new`, then adds `metadata`
          with `wasm-tools metadata add`. The module keeps its file name.
          The `wasmComponent` preset's last stage before `install`.
        '';
        options = {
          adapter = mkOption {
            type = types.nullOr (
              types.oneOf [
                types.package
                types.path
                (types.submodule {
                  options = {
                    name = mkOption {
                      type = types.str;
                      description = "The import module the adapter implements.";
                    };
                    module = mkOption {
                      type = types.either types.package types.path;
                      description = "The adapter module file.";
                    };
                  };
                })
              ]
            );
            default = null;
            example = literalExpression "{ name = \"wasi_snapshot_preview1\"; module = ./wasi_snapshot_preview1.reactor.wasm; }";
            description = ''
              An adapter module (`--adapt`) that implements imports of
              the core module not bound to WIT interfaces, such as
              `wasi_snapshot_preview1`. Either a module file, whose file
              name wasm-tools takes as the import module's name, or
              `{ name; module; }`, where `name` is the import module it
              implements.
            '';
          };
          metadata = mkOption {
            type = types.submodule {
              freeformType = types.attrsOf (
                types.oneOf [
                  types.str
                  (types.listOf types.str)
                  (types.attrsOf types.str)
                ]
              );
              options = {
                name = metadataString "The component's name, in the names section.";
                language = metadataProducers "Source languages" { Rust = "1.99.0"; };
                processedBy = metadataProducers "Tools that processed the component" { breakbulk = "0.1.0"; };
                sdk = metadataProducers "SDKs" { wasi-sdk = "25"; };
                authors = metadataString "The people or organisation responsible.";
                description = metadataString "A description.";
                licenses = metadataString "The licenses, as an SPDX expression.";
                source = metadataString "A URL of the source code.";
                homepage = metadataString "A URL with more information.";
                revision = metadataString "The source control revision.";
                version = metadataString "The version of the packaged software.";
              };
            };
            default = { };
            example = {
              name = "comp";
              processedBy.breakbulk = "0.1.0";
              licenses = "MIT OR Apache-2.0";
            };
            description = ''
              Metadata for `wasm-tools metadata add`. Each field is the
              flag of its name in kebab case (`processedBy` is
              `--processed-by`): a string or a list of strings is passed
              once per value, an attribute set as `NAME=VERSION` per
              entry. Fields not listed here are passed the same way, for
              flags of later wasm-tools versions.
            '';
          };
          wasmTools = toolOption "wasm-tools";
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        let
          adapt =
            if cfg.adapter == null then
              [ ]
            else if isAttrs cfg.adapter && !(isDerivation cfg.adapter) then
              [
                "--adapt"
                "${cfg.adapter.name}=${cfg.adapter.module}"
              ]
            else
              [
                "--adapt"
                "${cfg.adapter}"
              ];
          meta = metadataArgs cfg.metadata;
        in
        pkgs.runCommand (stageName product "componentize")
          { nativeBuildInputs = [ (toolOf cfg.wasmTools pkgs "wasm-tools") ]; }
          ''
            set -euo pipefail
            ${copyIn input}
            work=$out
            copyIn "$out"
            ${oneWasm "componentize"}
            wasm-tools component new "$wasm" ${escapeShellArgs adapt} -o "$wasm.component"
            ${
              if meta == [ ] then
                ''mv "$wasm.component" "$wasm"''
              else
                ''
                  wasm-tools metadata add ${escapeShellArgs meta} "$wasm.component" -o "$wasm"
                  rm "$wasm.component"
                ''
            }
          ''
      );

  # ---------------------------------------------------------------------
  # Packaging

  # 1980-01-01T00:00:00Z, the earliest time a zip (DOS) timestamp can hold.
  zipEpoch = "315532800";

  deterministicZip =
    mkHelper
      {
        name = "deterministicZip";
        description = ''
          Packs the input's files into one zip file whose bytes depend
          only on the files' contents, names and execute bits: entries
          in byte order of their paths, every time 1980-01-01 00:00 UTC,
          modes 0644 or 0755, no owners, extra timestamps or directory
          entries. The output is a directory holding the zip file.
        '';
        options = {
          name = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "app-linux-x86_64.zip";
            description = "The zip file's name. `null`: `<product name>.zip`.";
          };
          zip = toolOption "zip";
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        let
          fileName = if cfg.name != null then cfg.name else "${product.name}.zip";
        in
        pkgs.runCommand (stageName product "zip")
          { nativeBuildInputs = [ (toolOf cfg.zip pkgs "zip") ]; }
          ''
            set -euo pipefail
            ${copyIn input}
            tree=$TMPDIR/tree
            copyIn "$tree"
            # Normalise everything zip records: modes (0644, or 0755 when any
            # execute bit is set), times, and entry order (byte order of the
            # path). -X drops uid/gid and extended timestamps, -D directory
            # entries; TZ=UTC because zip stores local time.
            find "$tree" -type d -exec chmod 0755 {} +
            find "$tree" -type f -perm /111 -exec chmod 0755 {} +
            find "$tree" -type f ! -perm /111 -exec chmod 0644 {} +
            find "$tree" -exec touch -h -d @${zipEpoch} {} +
            mkdir -p "$out"
            cd "$tree"
            find . -mindepth 1 -type f | sed 's|^\./||' | LC_ALL=C sort \
              | TZ=UTC zip -X -D -q -@ "$out"/${escapeShellArg fileName}
          ''
      );

  install = mkHelper {
    name = "install";
    description = ''
      Lays the flat link output out as an installed tree. Every product
      has this stage unless `install = null` removes it.

      A root's file (`product.rootFiles`) goes by its kind: a bin to
      `bin/`, a staticlib to `lib/`, a cdylib or dylib to the target
      traits' `sharedLibraryDir` (`bin/` on Windows and Cygwin, where
      DLLs are found beside the executable; `lib/` elsewhere). Other
      files (renamed or added by a stage, import libraries) go by the
      traits' suffixes: static libraries and `.rlib` to `lib/`, shared
      libraries to `sharedLibraryDir`, executables to `bin/`. Where
      executables have no suffix, an executable file goes to `bin/`. A
      suffix that executables and shared libraries share (`.wasm`)
      decides nothing. A debug side file (`.pdb`) goes next to the file
      of the same stem, else to `bin/`. Anything else stays at the top.
      Top-level directories are copied as they are, so `bindgen`'s
      `pkg/` and a stage's `share/` are kept.

      The link units' debuginfo side files (`product.linkedDebug`:
      `.pdb`, `.dwp`, `.dwo`) go to a `debug` output in the same layout,
      so a `.pdb` sits in `$debug/bin` as its `.exe` does in `$out/bin`.
      Not when an earlier stage split debug information
      (`product.debugSplit`), whose `debug` output holds them, and not
      for wasm.
    '';
  } (
    _cfg:
    {
      input,
      product,
      target,
      pkgs,
      ...
    }:
    let
      t = traitsOf target pkgs;
      rootFiles = product.rootFiles or { };
      dirOfKind =
        k:
        if k == "bin" then
          "bin"
        else if k == "cdylib" || k == "dylib" then
          t.sharedLibraryDir
        else
          "lib";
      globOf =
        suffixes:
        lib.concatMapStringsSep "|" (x: "*${x}") (lib.unique (lib.filter (x: x != "") suffixes));
      ambiguous = t.executableSuffix != "" && t.executableSuffix == t.sharedLibrarySuffix;
      shared = lib.optionals (!ambiguous) [
        t.sharedLibrarySuffix
        "${t.sharedLibrarySuffix}.*"
      ];
      sideFiles = map (a: a.suffix) (
        lib.filter (a: !(a.perObject or false) && !(a.directory or false)) t.debugArtifacts
      );
      # File-name globs by destination; an import library (`.dll.lib`,
      # `.dll.a`) ends in the static suffix.
      globs = {
        lib = globOf (
          [
            t.staticLibrarySuffix
            ".rlib"
          ]
          ++ lib.optionals (t.sharedLibraryDir == "lib") shared
        );
        bin = globOf (
          lib.optional (!ambiguous) t.executableSuffix ++ lib.optionals (t.sharedLibraryDir == "bin") shared
        );
        side = globOf sideFiles;
      };
      # The side files go to install's own `debug` output when no earlier
      # stage split debug information (whose `debug` holds them already).
      debug = !t.isWasm && (product.linkedDebug or null) != null && !(product.debugSplit or false);
    in
    pkgs.runCommand (stageName product "install")
      (lib.optionalAttrs debug {
        outputs = [
          "out"
          "debug"
        ];
      })
      ''
        set -euo pipefail
        ${copyIn input}
        ${placeDebugFn product target pkgs}
        work=$TMPDIR/in
        copyIn "$work"
        mkdir -p "$out"
        ${lib.optionalString debug ''
          mkdir -p "$debug"
          placeDebug "$debug"
        ''}
        sides=()
        for f in "$work"/* "$work"/.[!.]*; do
          [ -e "$f" ] || continue
          b=$(basename "$f")
          if [ -d "$f" ]; then
            mkdir -p "$out/$b"; cp -R "$f"/. "$out/$b/"; continue
          fi
          case "$b" in
            ${lib.concatStrings (lib.mapAttrsToList (n: k: "${lib.escapeShellArg n}) dest=${dirOfKind k} ;;\n") rootFiles)}
            ${lib.optionalString (globs.side != "") "${globs.side}) sides+=(\"$f\"); continue ;;"}
            ${lib.optionalString (globs.lib != "") "${globs.lib}) dest=lib ;;"}
            ${lib.optionalString (globs.bin != "") "${globs.bin}) dest=bin ;;"}
            ${if t.executableSuffix == "" then ''*) if [ -x "$f" ]; then dest=bin; else dest=.; fi ;;'' else "*) dest=. ;;"}
          esac
          mkdir -p "$out/$dest"
          cp "$f" "$out/$dest/$b"
        done
        for f in "''${sides[@]}"; do
          b=$(basename "$f")
          dest=bin
          for d in bin lib; do
            if compgen -G "$out/$d/''${b%.*}.*" > /dev/null; then dest=$d; break; fi
          done
          mkdir -p "$out/$dest"
          cp "$f" "$out/$dest/$b"
        done
      ''
  );

  # Shell lines defining `placedFiles`, which prints, one per line, the
  # files the target's build scripts placed next to the binaries: the
  # regular files and symlinks directly in each `<profile>` copy a run's
  # `directives.json` names (`targetDirs`, the entries not ending in
  # `/deps`; #23). Cargo's `target/<profile>` holds them beside the bins,
  # where `cargo run` and a Windows loader find them.
  placedFilesFn =
    helperName: product: pkgs:
    let
      flags = product.buildScriptFlags or null;
      # A list of `flags` outputs (IFD mode), or `{ rootInfo; }`, the
      # roots' `breakbulk-root.json` files that list them
      # (`buildScriptFlags`; dynamic-derivation mode, known at build time).
      flagsList =
        if builtins.isList flags then
          lib.concatMapStringsSep " " (f: lib.escapeShellArg "${f}") flags
        else
          "$(${pkgs.buildPackages.jq}/bin/jq -r '(.buildScriptFlags // [])[]' ${lib.escapeShellArgs flags.rootInfo} | sort -u)";
    in
    if flags == null then
      throw "breakbulk stage helper `${helperName}`: this product does not know its target's build-script runs (`product.buildScriptFlags`; #23)"
    else
      ''
        placedFiles() {
          local f d
          for f in ${flagsList}; do
            f=$f/directives.json
            ${pkgs.buildPackages.jq}/bin/jq -r '(.targetDirs // [])[] | select(endswith("/deps") | not)' "$f"
          done | while IFS= read -r d; do
            find "$d" -mindepth 1 -maxdepth 1 \( -type f -o -type l \)
          done | sort -u
        }
      '';

  buildScriptFiles = mkHelper {
    name = "buildScriptFiles";
    description = ''
      Copies the files the build scripts of the product's target
      placed next to the binaries (Cargo's `target/<profile>`, where
      `cargo run` and a Windows loader find them: shared libraries that
      sdl2-sys `bundled` or ort-sys `copy-dylibs` copy there, Tauri's
      external binaries and resources) into the product, beside its own
      files. `install` then lays them out with them: a DLL next to the
      `.exe` in `bin/`, a `.so` in `lib/`, where on Linux the binary
      needs a run path to find it (`patchelfRpath`). Symlinks are
      resolved. A file name the product already has fails the stage.
      Run it before `install`.
    '';
  } (
    _cfg:
    {
      input,
      product,
      pkgs,
      ...
    }:
    pkgs.runCommand (stageName product "buildScriptFiles") { } ''
      set -euo pipefail
      ${copyIn input}
      ${placedFilesFn "buildScriptFiles" product pkgs}
      copyIn "$out"
      placedFiles | while IFS= read -r f; do
        b=''${f##*/}
        if [ -e "$out/$b" ]; then
          echo "buildScriptFiles: ${product.name} already has $b; a build script also placed $f" >&2
          exit 1
        fi
        cp -L "$f" "$out/$b"
        echo "buildScriptFiles: ${product.name}: $b (from $f)"
      done
    ''
  );

  # ---------------------------------------------------------------------
  # Checks

  # The last line of a failing check's message: how to remove it. The
  # name comes from `product.checkName`, not the helper's name, because a
  # check may run a helper under another name (linuxPortable's
  # `portableLibraries`).
  removeCheckLine =
    helperName: product: when:
    "or, when ${product.name} ${when}: packages.${product.name}.checks.${
      product.checkName or helperName
    } = null;";

  buildScriptFilesIncluded = mkHelper {
    name = "buildScriptFilesIncluded";
    kind = "check";
    description = ''
      Fails when a build script of the product's target placed files
      next to the binaries (Cargo's `target/<profile>`, where `cargo run`
      and a Windows loader find them) and the product holds no file of
      that name. The message names the files, the `buildScriptFiles`
      stage that includes them, at its place in this product's stage
      order, and how to remove the check. Every product has it as the
      check `buildScriptFiles`; it passes when no build script placed
      anything.
    '';
  } (
    _cfg:
    {
      input,
      product,
      pkgs,
      ...
    }:
    let
      # Where the stage goes in this product: after its last stage before
      # `install`, before `install` (when it has one).
      order = product.stageOrder or [ "install" ];
      installAt = lib.lists.findFirstIndex (s: s == "install") null order;
      before = if installAt == null then order else lib.take installAt order;
      position =
        lib.optionalString (before != [ ]) "after = \"${lib.last before}\"; "
        + lib.optionalString (lib.elem "install" order) "before = \"install\"; ";
      stanza = "packages.${product.name}.stages.buildScriptFiles = { ${position}run = breakbulk.stageHelpers.buildScriptFiles { }; };";
      removal = removeCheckLine "buildScriptFiles" product "does not need them at run time";
    in
    pkgs.runCommand "${product.name}-build-script-files" { inherit stanza removal; } ''
      set -euo pipefail
      ${placedFilesFn "buildScriptFilesIncluded" product pkgs}
      missing=()
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        b=''${f##*/}
        if [ -z "$(find ${input}/ -name "$b" -print -quit)" ]; then
          missing+=("$b (from $f)")
        fi
      done < <(placedFiles)
      if [ ''${#missing[@]} -gt 0 ]; then
        {
          echo "buildScriptFiles: build scripts placed files next to the binaries, where cargo run finds them, but ${product.name} does not include them:"
          printf '  %s\n' "''${missing[@]}"
          echo "Include them: $stanza"
          echo "$removal"
        } >&2
        exit 1
      fi
      touch $out
    ''
  );

  # Paths are compared as strings, so they are not realised for the check.
  # Only toolchain paths found in the closure cost a scan for the
  # libraries the output loads.
  noSourceReferences = mkHelper {
    name = "noSourceReferences";
    kind = "check";
    description = ''
      Fails when the closure of the checked output (by default the
      product's main output) contains a source path or a Rust toolchain
      path: a std panic location that names rust-src, or an embedded
      `CARGO`, makes the whole toolchain a run-time dependency. A
      separate `debug` output is not checked. Every product has this
      check unless it is removed.

      A source named only by files matching `sourcesAllowedIn` is
      allowed. One toolchain reference is allowed: a toolchain path
      holding a shared library the checked output loads (read from its
      files' ELF `NEEDED` entries and PE imports, looked up in the
      path's `lib`, `bin` and `lib/rustlib/<target>/{lib,bin}`). So a
      binary linked with `-C prefer-dynamic` may reference the sysroot
      whose `libstd-*.so` it loads; rustc's own component, cargo and
      rust-src never are. A rust-overlay toolchain's joined sysroot
      brings its rustc and cargo components along, so such a binary
      still fails there.
    '';
    options =
      let
        paths =
          what: default:
          mkOption {
            type = types.nullOr (types.listOf storePathType);
            default = null;
            description = "The ${what} store paths. `null`: ${default}.";
          };
      in
      {
        sources = paths "source" "the product's `sourcePaths` (its source views and crate sources)";
        toolchain =
          paths "Rust toolchain"
            "the product's `toolchainPaths` (rustc, its sysroot, cargo, rust-src). `[ ]` checks sources only";
        sourcesAllowedIn = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          example = [ "libapp-*.a" ];
          description = ''
            File name globs (in any directory) whose own references to
            sources are allowed; a source another file names still
            fails. `null`: the product's `sourcesAllowedIn` (each
            staticlib root's archive, whose objects keep their debug
            information for the final link).
          '';
        };
      };
  } (
    cfg:
    {
      input,
      product,
      pkgs,
      ...
    }:
    let
      sources = if cfg.sources != null then cfg.sources else product.sourcePaths or [ ];
      toolchain = if cfg.toolchain != null then cfg.toolchain else product.toolchainPaths or [ ];
      allowedIn = if cfg.sourcesAllowedIn != null then cfg.sourcesAllowedIn else product.sourcesAllowedIn or [ ];
      # The store path each source lies in, not the source itself: a git
      # crate's source is a directory inside its tree, and a closure lists
      # whole store paths only.
      storeRoot =
        s:
        let
          rel = lib.removePrefix "${builtins.storeDir}/" s;
        in
        if rel == s then s else "${builtins.storeDir}/${lib.head (lib.splitString "/" rel)}";
      strs = l: lib.unique (map (s: storeRoot (builtins.unsafeDiscardStringContext "${s}")) l);
      listFile = name: l: builtins.toFile name (concatStringsSep "\n" (strs l) + "\n");
      checkName = product.checkName or "noSourceReferences";
    in
    pkgs.runCommand "${product.name}-no-source-references"
      {
        closure = pkgs.closureInfo { rootPaths = [ input ]; };
        sourcesList = listFile "sources" sources;
        toolchainList = listFile "toolchain" toolchain;
        # readelf reads ELF of every architecture; objdump -p prints PE
        # imports ("DLL Name:").
        binutils = pkgs.buildPackages.binutils-unwrapped;
        allowedIn = concatStringsSep "\n" allowedIn;
        narrowing = "packages.${product.name}.checks.${checkName}.run = breakbulk.stageHelpers.noSourceReferences { toolchain = [ ]; };";
        removal = removeCheckLine "noSourceReferences" product "may reference them";
      }
      ''
        set -euo pipefail
        bad=0
        # The shared libraries the checked output's files load (computed
        # once, on first use).
        needed=
        neededLibs() {
          [ -z "$needed" ] || return 0
          needed=$TMPDIR/needed
          find -L ${input} -type f | while IFS= read -r f; do
            { "$binutils/bin/readelf" -d "$f" 2>/dev/null || true; } \
              | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'
            { "$binutils/bin/objdump" -p "$f" 2>/dev/null || true; } \
              | sed -n 's/^[[:space:]]*DLL Name: *//p'
          done | sort -u > "$needed"
        }
        # Whether toolchain path "$1" holds a library the output loads.
        loadsFrom() {
          neededLibs
          local n d
          while IFS= read -r n; do
            [ -n "$n" ] || continue
            for d in "$1/lib" "$1/bin" "$1"/lib/rustlib/*/lib "$1"/lib/rustlib/*/bin; do
              if [ -e "$d/$n" ]; then
                echo "noSourceReferences: ${product.name} loads $n from the Rust toolchain's $1: allowed" >&2
                return 0
              fi
            done
          done < "$needed"
          return 1
        }
        while IFS= read -r s; do
          [ -n "$s" ] || continue
          if grep -qxF "$s" "$closure/store-paths"; then
            if [ -n "$allowedIn" ]; then
              excludes=()
              while IFS= read -r f; do excludes+=("--exclude=$f"); done <<< "$allowedIn"
              # -a: an archive is binary, and grep would only say so.
              if ! grep -RlqaF "''${excludes[@]}" "$s" ${input}; then
                echo "noSourceReferences: ${product.name} references source $s only from files matching ${concatStringsSep ", " allowedIn}: allowed" >&2
                continue
              fi
            fi
            echo "noSourceReferences: ${product.name} (${builtins.unsafeDiscardStringContext "${input}"}) references source $s" >&2
            bad=1
          fi
        done < "$sourcesList"
        while IFS= read -r s; do
          [ -n "$s" ] || continue
          if grep -qxF "$s" "$closure/store-paths" && ! loadsFrom "$s"; then
            echo "noSourceReferences: ${product.name} (${builtins.unsafeDiscardStringContext "${input}"}) references the Rust toolchain $s" >&2
            bad=1
          fi
        done < "$toolchainList"
        if [ "$bad" = 1 ]; then
          {
            echo "Source and toolchain paths must not reach shipped outputs; see \"Source paths and debug information\" in the breakbulk documentation: https://schlarpc.github.io/breakbulk/explanation/products.html#source-paths-and-debug-information"
            echo "A toolchain path is allowed only when it holds a shared library the product loads, such as libstd-*.so with -C prefer-dynamic."
            echo "Check sources only: $narrowing"
            echo "$removal"
          } >&2
          exit 1
        fi
        touch "$out"
      ''
  );
  # ---------------------------------------------------------------------
  # Run-time libraries

  # The sonames of glibc's own libraries, in every release since 2.17 (the
  # oldest a Rust std supports): what an ELF program for "any glibc Linux"
  # may load besides what it links statically, as manylinux's policy
  # (auditwheel) allows for Python wheels. GCC's runtime libraries are a
  # separate list (`gccRuntimeLibraries`). The dynamic loaders are matched
  # by name (`ld-linux-*.so.*`, `ld64.so.*`).
  glibcLibraries = [
    "libc.so.6"
    "libm.so.6"
    "libmvec.so.1"
    "libpthread.so.0"
    "libdl.so.2"
    "librt.so.1"
    "libutil.so.1"
    "libresolv.so.2"
    "libnsl.so.1"
    "libcrypt.so.1"
    "libanl.so.1"
    "libBrokenLocale.so.1"
    "libthread_db.so.1"
    "ld-linux-*.so.*"
    "ld-linux.so.*"
    "ld64.so.*"
  ];

  # GCC's runtime libraries, which manylinux's policy (PEP 599 and later)
  # also allows, since nearly every glibc system has them: the unwinder
  # and C++ standard library a C++ dependency built with g++ loads.
  # linuxPortable allows them by default; a Rust program
  # linked by zig needs neither (zig links its own unwinder).
  gccRuntimeLibraries = [
    "libgcc_s.so.1"
    "libstdc++.so.6"
  ];

  # Like auditwheel's policy check, it reads the files, not their
  # store-path references, so it holds for a library found anywhere at
  # run time.
  neededLibraries =
    mkHelper
      {
        name = "neededLibraries";
        kind = "check";
        description = ''
          Fails when an ELF file in the checked output names in `NEEDED`
          (the shared libraries the dynamic loader loads for it) a
          library that `allowed` does not match, naming the file, the
          library and `why`. It reads the files, as auditwheel reads a
          wheel, so it holds wherever the library is found at run time.
          `linuxPortable`'s `portableLibraries` check.
        '';
        options = {
          allowed = mkOption {
            type = types.listOf types.str;
            default = glibcLibraries;
            defaultText = literalExpression "breakbulk.stageHelpers.glibcLibraries";
            example = literalExpression "breakbulk.stageHelpers.glibcLibraries ++ breakbulk.stageHelpers.gccRuntimeLibraries ++ [ \"libz.so.1\" ]";
            description = ''
              Shell glob patterns of the sonames a file may need.
              `breakbulk.stageHelpers.glibcLibraries` lists glibc's own
              libraries in every release since 2.17 and its dynamic
              loaders; `gccRuntimeLibraries` lists `libgcc_s.so.1` and
              `libstdc++.so.6`, which manylinux's policy also allows.
            '';
          };
          why = mkOption {
            type = types.str;
            default = "";
            example = "a portable Linux binary loads only glibc's libraries";
            description = "Why other libraries are not allowed, for the failure message.";
          };
          binutils = toolOption "binutils-unwrapped-all-targets";
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        pkgs.runCommand (stageName product "neededLibraries")
          {
            nativeBuildInputs = [ (binutilsOf cfg pkgs) ];
            removal = removeCheckLine "neededLibraries" product "may load them";
          }
          ''
            set -euo pipefail
            ${isElfFn}
            allowed=(${escapeShellArgs cfg.allowed})
            why=${escapeShellArg (lib.optionalString (cfg.why != "") ": ${cfg.why}")}
            bad=0
            mkdir -p $out
            while IFS= read -r -d "" f; do
              isElf "$f" || continue
              rel=''${f#${input}/}
              while IFS= read -r lib; do
                ok=0
                for p in "''${allowed[@]}"; do
                  # Unquoted: a glob pattern.
                  if [[ $lib == $p ]]; then ok=1; break; fi
                done
                if [ "$ok" = 1 ]; then
                  echo "$rel: $lib" >> $out/needed
                else
                  echo "neededLibraries: ${product.name}: $rel needs $lib, which is not an allowed run-time library$why" >&2
                  bad=1
                fi
              done < <(readelf -dW "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p')
            done < <(find -L ${input} -type f -print0 | LC_ALL=C sort -z)
            if [ "$bad" = 1 ]; then
              echo "$removal" >&2
              exit 1
            fi
            touch $out/needed
          ''
      );
  # Not Nix's reference scan, which sees only the hashes of the build's
  # inputs: this also finds paths outside the closure and paths whose
  # hash `remove-references-to` replaced with `eee…`.
  noStorePaths =
    mkHelper
      {
        name = "noStorePaths";
        kind = "check";
        description = ''
          Fails when a file in the checked output names a Nix store
          path anywhere in its bytes (any `<storeDir>/<32
          characters>-<name>` string), naming every file and path. A
          program for other systems must not look for a file in a store
          that is not there: a statically linked OpenSSL's `OPENSSLDIR`,
          a run path, an embedded tool path. `linuxPortable`'s
          `portableNoStorePaths` check.
        '';
        options = {
          allow = mkOption {
            type = types.listOf storePathType;
            default = [ ];
            example = [ "*-openssl-*-etc" ];
            description = ''
              The store paths a file may name: shell glob patterns
              matched against each whole path found
              (`/nix/store/<hash>-<name>…`, cut at the first character
              that cannot be in a store path name), or derivations and
              store paths, each matching itself and what lies below it.
            '';
          };
          why = mkOption {
            type = types.str;
            default = "";
            description = "Why store paths are not allowed, for the failure message.";
          };
        };
      }
      (
        cfg:
        {
          input,
          product,
          pkgs,
          ...
        }:
        let
          patterns = lib.concatMap (
            a:
            let
              s = builtins.unsafeDiscardStringContext (toString a);
            in
            # A store path matches itself and anything below it.
            if lib.hasPrefix "${builtins.storeDir}/" s && !(lib.hasInfix "*" s) then
              [
                s
                "${s}/*"
              ]
            else
              [ s ]
          ) cfg.allow;
        in
        pkgs.runCommand (stageName product "noStorePaths") {
          removal = removeCheckLine "noStorePaths" product "may name them";
        } ''
          set -euo pipefail
          allowed=(${escapeShellArgs patterns})
          why=${escapeShellArg (lib.optionalString (cfg.why != "") ": ${cfg.why}")}
          bad=0
          mkdir -p $out
          : > $out/allowed
          while IFS= read -r -d "" f; do
            rel=''${f#${input}/}
            while IFS= read -r p; do
              ok=0
              for a in "''${allowed[@]}"; do
                # Unquoted: a glob pattern.
                if [[ $p == $a ]]; then ok=1; break; fi
              done
              if [ "$ok" = 1 ]; then
                echo "$rel: $p" >> $out/allowed
              else
                echo "noStorePaths: ${product.name}: $rel names the Nix store path $p$why" >&2
                bad=1
              fi
            done < <({ LC_ALL=C grep -aoE '${lib.escapeRegex builtins.storeDir}/[0-9a-z]{32}-[A-Za-z0-9+._?=/-]*' "$f" || true; } | LC_ALL=C sort -u)
          done < <(find -L ${input} -type f -print0 | LC_ALL=C sort -z)
          if [ "$bad" = 1 ]; then
            echo "A portable product must not name the Nix store; allow a path with \`stageHelpers.noStorePaths { allow = [ \"<glob>\" ]; }\`." >&2
            echo "$removal" >&2
            exit 1
          fi
        ''
      );
in
{
  # Whether a value is a helper made by mkHelper (the attribute set also
  # holds plain values, such as glibcLibraries).
  isHelper = v: isAttrs v && v ? __functor && v ? kind && v ? options;

  inherit
    mkHelper
    noStorePaths
    splitDebug
    strip
    patchelfRpath
    bindgen
    wasmOpt
    componentize
    deterministicZip
    install
    buildScriptFiles
    buildScriptFilesIncluded
    noSourceReferences
    neededLibraries
    glibcLibraries
    gccRuntimeLibraries
    ;
}
