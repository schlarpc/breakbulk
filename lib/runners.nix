# Test runners for cross targets ("runner" in the target spec;
# "Tests as products" in docs/src/explanation/products.md).
#
# A runner is an executable invoked as Cargo invokes `target.<triple>.runner`:
#
#   <runner> <program> [args...]
#
# with the working directory, environment and TMPDIR of the test-run
# derivation that calls it. Each runner keeps any state it needs (a wine
# prefix, a browser profile) under $TMPDIR, so it works inside the Nix
# sandbox with no display, network or writable home.
#
#   runners = breakbulk.runners;
#   runners.wine { inherit pkgs; }                       x86_64 (and i686) Windows .exe
#   runners.qemuUser { inherit pkgs; arch = "aarch64"; } Linux ELF for another CPU
#   runners.wasmtime { inherit pkgs; }                    WASI modules and components
#   runners.wasmBindgenTest { inherit pkgs; wasmBindgen; browser = "node"; }
#                                                        wasm-bindgen-test binaries
#                                                        (or "chromium", "firefox")
#   runners.none { inherit pkgs; triple; }               no way to run: fails naming
#                                                        the options that give one
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
  # LD_LIBRARY_PATH it does not, exit status 53). So test runs give the
  # dynamic-library path to Windows test binaries as WINEPATH
  # (`breakbulkDylibPath`, read by testRuns.dylibPathOf).
  wine =
    {
      pkgs,
      wine ? pkgs.wineWow64Packages.minimal,
    }:
    (script pkgs "breakbulk-runner-wine" ''
      tmp="''${TMPDIR:-/tmp}"
      export HOME="$tmp/wine-home" WINEPREFIX="$tmp/wine-prefix"
      export WINEDEBUG="''${WINEDEBUG:--all}" WINEDLLOVERRIDES="''${WINEDLLOVERRIDES:-mscoree,mshtml=}"
      mkdir -p "$HOME"
      if [ ! -e "$WINEPREFIX/system.reg" ]; then
        ${wine}/bin/wineboot --init >/dev/null 2>&1 || true
      fi
      exec ${wine}/bin/wine "$@"
    '')
    // {
      breakbulkDylibPath = {
        var = "WINEPATH";
        sep = ";";
      };
    };

  # For a target whose programs nothing here can run. A test run under it
  # fails with what to set; `breakbulkNoRunner` keeps such runs and
  # doctests out of repo.checks (`canRunTests` on the target's outputs).
  # Setting the target's `runner` or `testSystem` replaces it.
  none =
    { pkgs, triple }:
    (script pkgs "breakbulk-runner-none-${triple}" ''
      echo 'breakbulk: nothing runs ${triple} programs on this machine, so its tests cannot run. Set targets."${triple}".runner (a program, as Cargo'"'"'s target.<triple>.runner) or targets."${triple}".testSystem (a Nix system whose builders run them).' >&2
      exit 1
    '')
    // {
      breakbulkNoRunner = true;
    };

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
