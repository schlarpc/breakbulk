# Stage and check helpers ("Stage helpers" in docs/implementation.md).
#
# Every helper is usable two ways:
#
#   run = helpers.wasmOpt;                          # defaults
#   run = helpers.wasmOpt { flags = [ "-O3" ]; };   # configured
#
# A helper is a function of one attribute set. Called with the stage
# arguments (`{ input, product, target, pkgs }`, recognised by `input`) it
# builds the stage; called with anything else it returns the same helper
# with those options set. Unknown options are an evaluation error.
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
    ;

  mkHelper =
    helperName: defaults: impl:
    let
      make =
        cfg: arg:
        if arg ? input then
          impl cfg arg
        else
          let
            unknown = attrNames (removeAttrs arg (attrNames defaults));
          in
          if unknown != [ ] then
            throw "breakbulk stage helper `${helperName}`: unknown option(s) ${concatStringsSep ", " unknown}; known options: ${
              if defaults == { } then "(none)" else concatStringsSep ", " (attrNames defaults)
            }"
          else
            make (cfg // arg);
    in
    make defaults;

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
  layoutOf =
    t:
    if t.isWasm then
      "wasm"
    else if t.isWindows then
      "windows"
    else
      "unix";

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

  # Decision 89: the debuginfo side files of the product's link units
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

  binutilsOf =
    cfg: pkgs: if cfg.binutils != null then cfg.binutils else pkgs.binutils-unwrapped-all-targets;

  # ---------------------------------------------------------------------
  # ELF

  splitDebug = mkHelper "splitDebug" { binutils = null; } (
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
        nativeBuildInputs = [ (binutilsOf cfg pkgs) ];
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
          # With split-debuginfo = "packed", the DWARF objects are in
          # `<binary>.dwp`. gdb looks for it next to the separate debug file
          # it found, under the binary's name (gdb 17.2,
          # gdb/dwarf2/read.c, open_and_init_dwp_file), so it moves there;
          # its install-layout place keeps a relative symlink.
          b=''${f##*/}
          for d in bin lib; do
            if [ -f "$debug/$d/$b.dwp" ] && [ ! -L "$debug/$d/$b.dwp" ]; then
              mv "$debug/$d/$b.dwp" "$dir/$b.dwp"
              ln -s "../lib/debug/.build-id/''${id:0:2}/$b.dwp" "$debug/$d/$b.dwp"
            fi
          done
        done
      ''
  );

  strip =
    mkHelper "strip"
      {
        all = false;
        binutils = null;
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
    mkHelper "patchelfRpath"
      {
        libs = [ ];
        patchelf = null;
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
          patchelf = if cfg.patchelf != null then cfg.patchelf else pkgs.patchelf;
        in
        if cfg.libs == [ ] then
          throw "breakbulk stage helper `patchelfRpath`: `libs` is empty"
        else
          pkgs.runCommand (stageName product "patchelfRpath") { nativeBuildInputs = [ patchelf ]; } ''
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
    mkHelper "bindgen"
      {
        target = "web";
        wasmBindgen = null;
        extraArgs = [ ];
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
          mkdir -p "$out"
          wasm-bindgen --target ${escapeShellArg cfg.target} --out-dir "$out" \
            ${escapeShellArgs cfg.extraArgs} "$wasm"
        ''
      );

  # `features`: the wasm features wasm-opt may assume, as `--enable-<f>`.
  # The default is what rustc enables on wasm32-unknown-unknown since 1.87
  # (its CARGO_CFG_TARGET_FEATURE); wasm-opt's own default is the MVP, and
  # it rejects a Rust module using memory.copy ("memory.copy operations
  # require bulk memory operations").
  wasmOpt =
    mkHelper "wasmOpt"
      {
        flags = [ "-Oz" ];
        features = [
          "bulk-memory"
          "multivalue"
          "mutable-globals"
          "nontrapping-float-to-int"
          "reference-types"
          "sign-ext"
        ];
        binaryen = null;
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
          { nativeBuildInputs = [ (if cfg.binaryen != null then cfg.binaryen else pkgs.binaryen) ]; }
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
      ) metadata
    );

  componentize =
    mkHelper "componentize"
      {
        adapter = null;
        metadata = { };
        wasmTools = null;
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
          { nativeBuildInputs = [ (if cfg.wasmTools != null then cfg.wasmTools else pkgs.wasm-tools) ]; }
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
    mkHelper "deterministicZip"
      {
        name = null;
        zip = null;
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
          { nativeBuildInputs = [ (if cfg.zip != null then cfg.zip else pkgs.zip) ]; }
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

  # Final layout, by the target's traits (`traitsOf`):
  #   wasm:    everything under pkg/
  #   windows: .exe, .dll, .pdb under bin/ (DLLs next to the executable);
  #            .lib under lib/
  #   others:  executables under bin/; .so*, .a, .rlib under lib/
  # The link units' debuginfo side files (`product.linkedDebug`: `.pdb`,
  # `.dwp`, `.dwo`) go to a `debug` output in the same layout, so `.pdb`
  # sits in `$debug/bin` as the `.exe` does in `$out/bin`; only when no
  # earlier stage split debug information (`product.debugSplit`), whose
  # `debug` output holds them instead, and not for wasm.
  # Top-level directories of the input are copied unchanged, so a stage
  # that already produced bin/ or share/ keeps it; other top-level files are
  # copied to the top level unchanged.
  install = mkHelper "install" { } (
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
      kind = layoutOf t;
      # File-name globs from the target's traits (#17): libraries (static,
      # `.rlib`, and on unix shared ones, also versioned `.so.1`) go to
      # lib/; executables, and on Windows DLLs and the debug side files
      # that sit next to them (`.pdb`), go to bin/. An import library
      # (`.dll.lib`, `.dll.a`) ends in the static suffix. Elsewhere an
      # executable file goes to bin/; anything else stays at the top.
      globOf =
        suffixes:
        lib.concatMapStringsSep "|" (x: "*${x}") (lib.unique (lib.filter (x: x != "") suffixes));
      sideFiles = map (a: a.suffix) (
        lib.filter (a: !(a.perObject or false) && !(a.directory or false)) t.debugArtifacts
      );
      globs = {
        lib = globOf (
          [
            t.staticLibrarySuffix
            ".rlib"
          ]
          ++ lib.optionals (kind == "unix") [
            t.sharedLibrarySuffix
            "${t.sharedLibrarySuffix}.*"
          ]
        );
        bin = globOf (
          [ t.executableSuffix ]
          ++ lib.optionals (kind == "windows") ([ t.sharedLibrarySuffix ] ++ sideFiles)
        );
      };
      # The side files go to install's own `debug` output when no earlier
      # stage split debug information (whose `debug` holds them already).
      debug = kind != "wasm" && (product.linkedDebug or null) != null && !(product.debugSplit or false);
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
        ${
          if kind == "wasm" then
            ''
              mkdir -p "$out/pkg"
              cp -R "$work"/. "$out/pkg/"
            ''
          else
            ''
              for f in "$work"/* "$work"/.[!.]*; do
                [ -e "$f" ] || continue
                b=$(basename "$f")
                if [ -d "$f" ]; then
                  mkdir -p "$out/$b"; cp -R "$f"/. "$out/$b/"; continue
                fi
                case "$b" in
                  ${globs.lib}) dest=lib ;;
                  ${lib.optionalString (globs.bin != "") "${globs.bin}) dest=bin ;;"}
                  ${if kind == "unix" then ''*) if [ -x "$f" ]; then dest=bin; else dest=.; fi ;;'' else "*) dest=. ;;"}
                esac
                mkdir -p "$out/$dest"
                cp "$f" "$out/$dest/$b"
              done
            ''
        }
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
      # A list of `flags` outputs (IFD mode), or `{ file; }` listing them,
      # one per line (dynamic-derivation mode, known at build time).
      flagsList =
        if builtins.isList flags then
          lib.concatMapStringsSep " " (f: lib.escapeShellArg "${f}") flags
        else
          "$(cat ${lib.escapeShellArg flags.file})";
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

  # #23: copy the files the target's build scripts placed next to
  # the binaries (as in Cargo's `target/<profile>`: shared libraries that
  # sdl2-sys `bundled` or ort-sys `copy-dylibs` copy there, Tauri's
  # external binaries and resources) into the product, beside its own
  # files, so `install` lays them out with them (a DLL next to the .exe in
  # bin/, a `.so` in lib/; on Linux the binary then needs a runpath to
  # find it, e.g. `patchelfRpath`). Symlinks are resolved. A name the
  # product already has is an error.
  buildScriptFiles = mkHelper "buildScriptFiles" { } (
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

  # Fails when the closure of the checked output (by default the product's
  # main output) contains any of `sources` (store paths; default: the
  # product's `sourcePaths`) or of `toolchain` (default: the product's
  # `toolchainPaths`: rustc, its sysroot, cargo, rust-src; a std panic
  # location that names rust-src, or an embedded `CARGO`, makes the whole
  # toolchain a runtime dependency). Only `${input}` is checked, so a
  # separate `debug` output is exempt. Paths are compared as strings, so
  # they are not realised for the check.
  #
  # One toolchain reference is allowed (decision 134): a toolchain path
  # that holds a shared library the checked output itself loads. The
  # needed libraries are read from the output's files (ELF `NEEDED`, PE
  # imports), and a toolchain path is allowed when one of them is a file in
  # its `lib`, `bin` or `lib/rustlib/<target>/{lib,bin}`. So a binary linked
  # with `-C prefer-dynamic` may reference the sysroot whose `libstd-*.so`
  # it loads, while rustc's own component, cargo and rust-src, which hold
  # no such library, never are. (A rust-overlay toolchain's joined sysroot
  # brings its rustc and cargo components along, so such a binary still
  # fails there.) Only toolchain paths found in the closure cost a scan.
  # The default `buildScriptFiles` check (#23), on products of targets
  # whose build plan has build-script runs: fails when a build script
  # placed files next to the binaries (Cargo's `target/<profile>`, where
  # `cargo run` and a Windows loader find them) and the product holds no
  # file of that name, naming the files and the two ways out.
  buildScriptFilesIncluded = mkHelper "buildScriptFilesIncluded" { } (
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
      before = lib.filter (s: s != "install") order;
      position =
        lib.optionalString (before != [ ]) "after = \"${lib.last before}\"; "
        + lib.optionalString (lib.elem "install" order) "before = \"install\"; ";
      stanza = "packages.${product.name}.stages.buildScriptFiles = { ${position}run = breakbulk.stageHelpers.buildScriptFiles { }; };";
    in
    pkgs.runCommand "${product.name}-build-script-files" { inherit stanza; } ''
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
          echo "or, when ${product.name} does not need them at run time: packages.${product.name}.checks.buildScriptFiles = null;"
        } >&2
        exit 1
      fi
      touch $out
    ''
  );

  noSourceReferences = mkHelper "noSourceReferences" { sources = null; toolchain = null; } (
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
      strs = l: lib.unique (map (s: builtins.unsafeDiscardStringContext "${s}") l);
      listFile = name: l: builtins.toFile name (concatStringsSep "\n" (strs l) + "\n");
    in
    pkgs.runCommand "${product.name}-no-source-references"
      {
        closure = pkgs.closureInfo { rootPaths = [ input ]; };
        sourcesList = listFile "sources" sources;
        toolchainList = listFile "toolchain" toolchain;
        # readelf reads ELF of every architecture; objdump -p prints PE
        # imports ("DLL Name:").
        binutils = pkgs.buildPackages.binutils-unwrapped;
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
          echo "Source and toolchain paths must not reach shipped outputs; see \"Source paths and debug information\" in breakbulk's design." >&2
          echo "(A toolchain path is allowed only when it holds a shared library the product loads, such as libstd-*.so with -C prefer-dynamic; \`noSourceReferences { toolchain = [ ]; }\` checks sources only.)" >&2
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
  # linuxPortable allows them by default (decision 145); a Rust program
  # linked by zig needs neither (zig links its own unwinder).
  gccRuntimeLibraries = [
    "libgcc_s.so.1"
    "libstdc++.so.6"
  ];

  # A check: every ELF file in its input may name in NEEDED (the shared
  # libraries the dynamic loader loads for it) only `allowed`, shell glob
  # patterns of sonames; any other library fails the check, naming the
  # file, the library and `why`. Like auditwheel's policy check, it reads
  # the files, not their store-path references, so it holds for a
  # library found anywhere at run time.
  neededLibraries =
    mkHelper "neededLibraries"
      {
        allowed = glibcLibraries;
        why = "";
        binutils = null;
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
          { nativeBuildInputs = [ (binutilsOf cfg pkgs) ]; }
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
            [ "$bad" = 0 ]
            touch $out/needed
          ''
      );
  # A check (decision 144): no file in its input names a Nix store path,
  # anywhere in its bytes: a program for other systems must not look for a
  # file in a store that is not there (a statically linked OpenSSL's
  # OPENSSLDIR, an rpath, an embedded tool path). Unlike Nix's reference
  # scan, which sees only the hashes of the build's inputs, it matches any
  # `<storeDir>/<32 characters>-<name>` string, so it also finds paths
  # outside the closure and paths whose hash `remove-references-to`
  # replaced with `eee…`. `allow` takes shell glob patterns matched against
  # each whole path found (`/nix/store/<hash>-<name>…`, cut at the first
  # character that cannot be in a store path name), such as
  # "*-openssl-*-etc"; a derivation or store path matches itself and what
  # lies below it. It fails naming every file and path.
  noStorePaths =
    mkHelper "noStorePaths"
      {
        allow = [ ];
        why = "";
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
        pkgs.runCommand (stageName product "noStorePaths") { } ''
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
            exit 1
          fi
        ''
      );
in
{
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
