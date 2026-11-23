# Test runners for cross targets (`targets.<triple>.runner`; "Tests as
# products" in docs/src/explanation/products.md).
#
# A runner program is invoked as Cargo invokes `target.<triple>.runner`:
#
#   <runner> [args...] <program> [program args...]
#
# with the working directory, environment and TMPDIR of the test-run
# derivation that calls it. Each runner keeps any state it needs (a wine
# prefix, a browser profile) under $TMPDIR, so it works inside the Nix
# sandbox with no display, network or writable home. The values the
# option takes (null, false, a program, a list, a record with `args` and
# `dylibPath`) are in lib/modules/types.nix (`runner`, `runnerNote`);
# `toRecord` reads any of them.
#
#   runners = breakbulk.runners;
#   runners.wine { inherit pkgs; }                       x86_64 (and i686) Windows .exe
#                                                        (a record: its dylibPath is WINEPATH)
#   runners.qemuUser { inherit pkgs; arch = "aarch64"; } Linux ELF for another CPU
#   runners.ldSo { inherit pkgs; }                       ELF for the build machine that names
#                                                        the FHS loader (linuxPortable)
#   runners.adb { inherit pkgs; }                        Android programs on a device or
#                                                        emulator, outside the sandbox
#                                                        (a record: its dylibPath is the
#                                                        libraries to push)
#   runners.wasmtime { inherit pkgs; }                    WASI modules and components
#   runners.wasmBindgenTest { inherit pkgs; wasmBindgen; browser = "node"; }
#                                                        wasm-bindgen-test binaries
#                                                        (or "chromium", "firefox")
#   runners.none { inherit pkgs; triple; }               what a run under `runner = false`
#                                                        runs: fails naming the options
{ lib }:
let
  script =
    pkgs: name: text:
    pkgs.writeShellScript name ''
      set -euo pipefail
      ${text}
    '';
in
{
  # A runner value as `{ program; args; dylibPath; }`, or null (run
  # directly) or false (nothing runs the target's programs) unchanged.
  toRecord =
    v:
    if v == null || v == false then
      v
    else if builtins.isList v then
      {
        program = lib.head v;
        args = lib.tail v;
        dylibPath = null;
      }
    else if builtins.isAttrs v && v ? program && !(lib.isDerivation v) then
      {
        args = [ ];
        dylibPath = null;
      }
      // v
    else
      {
        program = v;
        args = [ ];
        dylibPath = null;
      };

  # The package set test runs build with: `pkgs` itself, or, for a target
  # whose tests run on another system (`testSystem`, a native builder),
  # nixpkgs for that system with the user's overlays and config (allowUnfree,
  # …).
  testPkgsFor =
    {
      pkgs,
      testSystem ? null,
    }:
    if testSystem == null || testSystem == pkgs.stdenv.buildPlatform.system then
      pkgs
    else
      import pkgs.path {
        system = testSystem;
        inherit (pkgs) overlays config;
      };

  # wine with a fresh prefix in $TMPDIR. `wine64` is
  # wineWow64Packages.minimal: 64-bit and 32-bit programs, no X11.
  #
  # A Windows program finds DLLs on its PATH, and the Windows PATH under
  # wine is not the Unix one: wine prepends WINEPATH, `;`-separated, whose
  # entries may be Unix paths (checked with wine 11.0: a DLL in a
  # directory named by WINEPATH loads; on the Unix PATH or
  # LD_LIBRARY_PATH it does not, exit status 53). So the runner is a
  # record whose `dylibPath` is WINEPATH, which test runs give the
  # dynamic-library path to Windows test binaries in.
  wine =
    {
      pkgs,
      wine ? pkgs.wineWow64Packages.minimal,
    }:
    {
      program = script pkgs "breakbulk-runner-wine" ''
        tmp="''${TMPDIR:-/tmp}"
        export HOME="$tmp/wine-home" WINEPREFIX="$tmp/wine-prefix"
        export WINEDEBUG="''${WINEDEBUG:--all}" WINEDLLOVERRIDES="''${WINEDLLOVERRIDES:-mscoree,mshtml=}"
        mkdir -p "$HOME"
        if [ ! -e "$WINEPREFIX/system.reg" ]; then
          ${wine}/bin/wineboot --init >/dev/null 2>&1 || true
        fi
        exec ${wine}/bin/wine "$@"
      '';
      args = [ ];
      dylibPath = {
        var = "WINEPATH";
        sep = ";";
      };
    };

  # What a test run of a target whose runner is `false` runs: it fails
  # with what to set.
  none =
    { pkgs, triple }:
    script pkgs "breakbulk-runner-none-${triple}" ''
      echo 'breakbulk: nothing runs ${triple} programs on this machine, so its tests cannot run. Set targets."${triple}".runner (a program, as Cargo'"'"'s target.<triple>.runner), or targets."${triple}".testSystem (a Nix system whose builders run them) with runner = null.' >&2
      exit 1
    '';

  # The build machine's ELF loader, for programs that name the FHS
  # loader path (/lib64/ld-linux-x86-64.so.2), as a program for other
  # distributions should (linuxPortable's zig links them so); the Nix
  # sandbox has none. The loader also finds its own libc.so.6.
  ldSo =
    { pkgs }:
    pkgs.writeShellScript "breakbulk-runner-ld-so" ''
      exec ${pkgs.stdenv.cc.bintools.dynamicLinker} "$@"
    '';

  # qemu user-mode emulation. Programs built against a nixpkgs cross libc
  # name their dynamic loader by store path, so no -L sysroot is needed.
  qemuUser =
    {
      pkgs,
      arch,
      qemu ? pkgs.qemu-user or pkgs.qemu,
    }:
    script pkgs "breakbulk-runner-qemu-${arch}" ''
      exec ${qemu}/bin/qemu-${arch} "$@"
    '';

  # An Android device or emulator through adb (nixpkgs' android-tools,
  # built from source, not the SDK's platform-tools): the program and the
  # shared libraries of its dynamic-library path are pushed to a fresh
  # directory under /data/local/tmp, run there with the `RUST_*` and
  # `CARGO_*` variables of the runner's environment (`adb shell` starts the
  # device's shell with none of the caller's), and removed. The device is
  # adb's choice: ANDROID_SERIAL, else the only one attached. Outside the
  # Nix sandbox only, which has no device: a test app, not a test run.
  #
  # A record whose `dylibPath` is BREAKBULK_ADB_LIBRARY_PATH: the test's
  # library directories are on the build machine, so the runner reads them
  # from there and gives the device its own copy as LD_LIBRARY_PATH.
  # `libraries`: directories whose shared libraries every program gets
  # too (presets.android: the NDK's libc++_shared.so, which an app ships
  # and the device does not have).
  adb =
    {
      pkgs,
      adb ? pkgs.android-tools,
      libraries ? [ ],
    }:
    {
      program = script pkgs "breakbulk-runner-adb" ''
        adb=${adb}/bin/adb
        if [ "$($adb get-state 2>/dev/null || true)" != device ]; then
          echo "breakbulk: adb finds no Android device or emulator (ANDROID_SERIAL=''${ANDROID_SERIAL:-<unset>}); start one, or attach a device, and run the test app again. A test run inside the Nix sandbox cannot reach one." >&2
          exit 1
        fi
        prog=$1
        shift
        quote() { printf "'%s'" "''${1//\'/\'\\\'\'}"; }
        dir=/data/local/tmp/breakbulk-$(${pkgs.coreutils}/bin/od -An -N8 -tx8 /dev/urandom | tr -d ' ')
        $adb shell "mkdir -p $dir/lib" >/dev/null
        trap '$adb shell "rm -rf $dir" >/dev/null 2>&1 || true' EXIT
        $adb push -q "$prog" "$dir/" >/dev/null
        IFS=: read -ra libdirs <<< "''${BREAKBULK_ADB_LIBRARY_PATH:-}"
        libdirs+=(${lib.escapeShellArgs (map toString libraries)})
        for d in "''${libdirs[@]}"; do
          for f in "$d"/*.so; do
            [ -e "$f" ] && $adb push -q "$f" "$dir/lib/" >/dev/null
          done
        done
        cmd="cd $dir && env LD_LIBRARY_PATH=$dir/lib"
        while IFS= read -r -d "" kv; do
          case $kv in
            RUST_*=* | CARGO_*=*) [[ $kv == *$'\n'* ]] || cmd+=" $(quote "$kv")" ;;
          esac
        done < <(${pkgs.coreutils}/bin/env -0)
        cmd+=" ./$(quote "''${prog##*/}")"
        for a in "$@"; do
          cmd+=" $(quote "$a")"
        done
        # adb's shell protocol (Android 7+) gives the program's exit status.
        $adb shell "$cmd"
      '';
      args = [ ];
      dylibPath = {
        var = "BREAKBULK_ADB_LIBRARY_PATH";
        sep = ":";
      };
    };

  wasmtime =
    {
      pkgs,
      wasmtime ? pkgs.wasmtime,
      extraArgs ? [ ],
    }:
    script pkgs "breakbulk-runner-wasmtime" ''
      # wasmtime caches compiled components under $XDG_CACHE_HOME (or
      # $HOME/.cache), which is unwritable in the sandbox.
      export XDG_CACHE_HOME="''${TMPDIR:-/tmp}/wasmtime-cache"
      exec ${wasmtime}/bin/wasmtime run ${lib.escapeShellArgs extraArgs} "$@"
    '';

  # wasm-bindgen-test-runner, which must be the exact version of the
  # wasm-bindgen crate the test was built with (breakbulk.wasmBindgen).
  # browser = "node": tests run in Node.js (wasm-bindgen-test's default for
  # tests without `run_in_browser`). browser = "chromium" or "firefox":
  # every test runs in that headless browser through its WebDriver
  # (chromedriver, geckodriver), with its profile under $TMPDIR; tests marked
  # `run_in_browser` need one.
  #
  # The sandbox has no /etc/fonts, and Chromium with no fontconfig
  # configuration aborts in Skia's font manager ("Not implemented") once a
  # page loads; chromedriver reports it as "Unable to receive message from
  # renderer". So the browsers get a fontconfig file listing `fonts`.
  # wasm-bindgen-test-runner itself starts Chromium with --no-sandbox and
  # --disable-dev-shm-usage.
  wasmBindgenTest =
    {
      pkgs,
      wasmBindgen,
      browser ? "node",
      nodejs ? pkgs.nodejs,
      chromium ? pkgs.chromium,
      chromedriver ? pkgs.chromedriver,
      firefox ? pkgs.firefox,
      geckodriver ? pkgs.geckodriver,
      fonts ? [ pkgs.dejavu_fonts ],
    }:
    assert lib.assertOneOf "browser" browser [
      "node"
      "chromium"
      "firefox"
    ];
    let
      # wasm-bindgen-test-runner reads webdriver.json from the working
      # directory for extra capabilities.
      inBrowser = driverEnv: capabilities: ''
        export ${driverEnv}
        export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = fonts; }}
        # Run tests in the browser even without `run_in_browser`.
        export WASM_BINDGEN_USE_BROWSER=1
        export WASM_BINDGEN_TEST_TIMEOUT="''${WASM_BINDGEN_TEST_TIMEOUT:-120}"
        work="$tmp/wbt-work"
        mkdir -p "$work"
        cat > "$work/webdriver.json" <<EOF
        ${capabilities}
        EOF
        prog="$(readlink -f "$1")"; shift
        cd "$work"
        exec ${wasmBindgen}/bin/wasm-bindgen-test-runner "$prog" "$@"
      '';
    in
    script pkgs "breakbulk-runner-wasm-bindgen-${browser}" (
      ''
        tmp="''${TMPDIR:-/tmp}"
        export HOME="$tmp/wbt-home"
        mkdir -p "$HOME"
        export PATH="${nodejs}/bin''${PATH:+:$PATH}"
      ''
      + {
        node = ''
          export WASM_BINDGEN_TEST_ONLY_NODE=1
          exec ${wasmBindgen}/bin/wasm-bindgen-test-runner "$@"
        '';
        chromium = inBrowser "CHROMEDRIVER=${chromedriver}/bin/chromedriver" ''
          {"goog:chromeOptions": {"binary": "${chromium}/bin/chromium",
            "args": ["--user-data-dir=$tmp/chromium-profile"]}}'';
        firefox = inBrowser "GECKODRIVER=${geckodriver}/bin/geckodriver" ''{"moz:firefoxOptions": {"binary": "${firefox}/bin/firefox"}}'';
      }
      .${browser}
    );
}
