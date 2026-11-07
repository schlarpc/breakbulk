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
{ lib, wasmBindgen }:
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
              case "${
                if lib.hasInfix "windows" (target.triple or pkgs.stdenv.hostPlatform.config) then
                  "windows"
                else
                  "unix"
              }:$b" in
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

  wasmOpt =
    mkHelper "wasmOpt"
      {
        flags = [ "-Oz" ];
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
              wasm-opt ${escapeShellArgs cfg.flags} "$f" -o "$f.opt"
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

  # Final layout. The platform comes from `target.triple` (or the stage
  # pkgs' host platform):
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
      triple = target.triple or pkgs.stdenv.hostPlatform.config;
      kind =
        if lib.hasPrefix "wasm" triple then
          "wasm"
        else if lib.hasInfix "windows" triple then
          "windows"
        else
          "unix";
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
                case "${kind}:$b" in
                  windows:*.exe|windows:*.dll|windows:*.pdb) dest=bin ;;
                  windows:*.lib) dest=lib ;;
                  unix:*.so|unix:*.so.*|unix:*.a|unix:*.rlib) dest=lib ;;
                  unix:*) if [ -x "$f" ]; then dest=bin; else dest=.; fi ;;
                  *) dest=. ;;
                esac
                mkdir -p "$out/$dest"
                cp "$f" "$out/$dest/$b"
              done
            ''
        }
      ''
  );

  # ---------------------------------------------------------------------
  # Checks

  # Fails when the closure of the checked output (by default the product's
  # main output) contains any of `sources` (store paths; default: the
  # product's `sourcePaths`). Only `${input}` is checked, so a separate
  # `debug` output is exempt. Sources are compared as strings, so they are
  # not realised for the check.
  noSourceReferences = mkHelper "noSourceReferences" { sources = null; } (
    cfg:
    {
      input,
      product,
      pkgs,
      ...
    }:
    let
      sources = if cfg.sources != null then cfg.sources else product.sourcePaths or [ ];
      strs = map (s: builtins.unsafeDiscardStringContext "${s}") sources;
    in
    pkgs.runCommand "${product.name}-no-source-references"
      {
        closure = pkgs.closureInfo { rootPaths = [ input ]; };
        sourcesList = builtins.toFile "sources" (concatStringsSep "\n" strs + "\n");
      }
      ''
        set -euo pipefail
        bad=0
        while IFS= read -r s; do
          [ -n "$s" ] || continue
          if grep -qxF "$s" "$closure/store-paths"; then
            echo "noSourceReferences: ${product.name} (${builtins.unsafeDiscardStringContext "${input}"}) references source $s" >&2
            bad=1
          fi
        done < "$sourcesList"
        if [ "$bad" = 1 ]; then
          echo "Source paths must not reach shipped outputs; see \"Source paths and debug information\" in breakbulk's design." >&2
          exit 1
        fi
        touch "$out"
      ''
  );
in
{
  inherit
    mkHelper
    splitDebug
    strip
    patchelfRpath
    bindgen
    wasmOpt
    componentize
    deterministicZip
    install
    noSourceReferences
    ;
}
