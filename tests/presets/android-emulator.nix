# The Android fixture's tests on an emulator (`nix run
# .#test-android-emulator`): its test apps
# (repo.workspaces.main.target.aarch64-linux-android.variants.default.testApps, which run
# each test binary through presets.android's adb runner) against the
# Android emulator, headless, with KVM, on an x86_64 Google APIs system
# image. That image runs arm64 programs through its ARM translation (the
# binfmt_misc handler `ro.enable.native.bridge.exec` registers); the
# emulator runs no arm64 image on an x86_64 machine.
#
# Opt-in, not a flake check: it needs /dev/kvm, which builds in the
# sandbox do not get, and downloads the emulator and a system image
# (~2 GB, unfree, under the Android SDK License Agreement, which running
# it accepts for this repository's tests). Arguments go to nix-store.
#
#   nix run .#test-android-emulator [-- --max-jobs 2]
{
  pkgs,
  breakbulk,
  # Image and emulator: androidenv's, from a package set that admits them.
  sdkPkgs ? import pkgs.path {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.android_sdk.accept_license = true;
    config.allowUnfreePredicate =
      p:
      pkgs.lib.elem (pkgs.lib.getName p) [
        "android-sdk-emulator"
        "emulator"
        "android-sdk-system-image-${apiLevel}-${imageType}-x86_64"
        "system-image-${apiLevel}-${imageType}-x86_64"
      ];
  },
  apiLevel ? "34",
  imageType ? "google_apis",
}:
let
  inherit (pkgs) lib;
  android = import ./android.nix { inherit pkgs breakbulk; };
  triple = "aarch64-linux-android";
  apps = android.repo.workspaces.main.target.${triple}.variants.default.testApps;
  # `<package>/<binary key>=<.drv>`, realised when the app runs.
  appDrvs = lib.concatLists (
    lib.mapAttrsToList (
      pkg: bins:
      lib.mapAttrsToList (k: d: "${pkg}/${k}=${builtins.unsafeDiscardOutputDependency d.drvPath}") bins
    ) apps
  );
  sdk = sdkPkgs.androidenv.composeAndroidPackages {
    includeEmulator = true;
    includeSystemImages = true;
    platformVersions = [ apiLevel ];
    systemImageTypes = [ imageType ];
    abiVersions = [ "x86_64" ];
  };
  drvOf = d: builtins.unsafeDiscardOutputDependency d.drvPath;
  adb = "${pkgs.android-tools}/bin/adb";
in
pkgs.writeShellScript "test-android-emulator" ''
  set -euo pipefail
  PATH=${
    lib.makeBinPath [
      pkgs.coreutils
      pkgs.gnugrep
    ]
  }:$PATH
  echo "== building the test apps, the emulator and the system image" >&2
  emu=$(nix-store --realise ${drvOf sdk.emulator} "$@")
  img=$(nix-store --realise ${drvOf (lib.head sdk.system-images)} "$@")
  declare -A app
  for nd in ${lib.escapeShellArgs appDrvs}; do
    app[''${nd%%=*}]=$(nix-store --realise "''${nd#*=}" "$@")
  done

  [ -w /dev/kvm ] || { echo "test-android-emulator: /dev/kvm is not writable; the emulator needs KVM" >&2; exit 1; }

  work=$(mktemp -d "''${TMPDIR:-/tmp}/bb-android-emulator.XXXXXX")
  pid=
  # The adb server is stopped at the end only when this started it.
  ownServer=
  if ${adb} start-server 2>&1 | grep -q 'started successfully'; then ownServer=1; fi
  cleanup() {
    if [ -n "$pid" ]; then
      ${adb} -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    if [ -n "$ownServer" ]; then ${adb} kill-server 2>/dev/null || true; fi
    rm -rf "$work"
  }
  trap cleanup EXIT

  # An SDK directory with the emulator and the image, and an AVD of it,
  # written directly (avdmanager would need the command-line tools and a
  # JDK).
  sdk=$work/sdk
  sysdir=system-images/android-${apiLevel}/${imageType}/x86_64
  mkdir -p "$sdk/$(dirname "$sysdir")" "$sdk/platforms" "$sdk/platform-tools" "$work/avd/bb.avd" "$work/home"
  ln -s "$emu/libexec/android-sdk/emulator" "$sdk/emulator"
  ln -s "$img/libexec/android-sdk/$sysdir" "$sdk/$sysdir"
  export ANDROID_HOME=$sdk ANDROID_SDK_ROOT=$sdk ANDROID_USER_HOME=$work/home ANDROID_AVD_HOME=$work/avd
  cat > "$work/avd/bb.ini" <<EOF
  avd.ini.encoding=UTF-8
  path=$work/avd/bb.avd
  target=android-${apiLevel}
  EOF
  cat > "$work/avd/bb.avd/config.ini" <<EOF
  abi.type=x86_64
  hw.cpu.arch=x86_64
  hw.cpu.ncore=2
  hw.ramSize=2048
  disk.dataPartition.size=2G
  image.sysdir.1=$sysdir/
  tag.id=${imageType}
  target=android-${apiLevel}
  EOF

  port=
  for p in $(seq 5554 2 5584); do
    if ! ${adb} devices | grep -q "emulator-$p"; then port=$p; break; fi
  done
  [ -n "$port" ] || { echo "test-android-emulator: no free emulator port" >&2; exit 1; }
  export ANDROID_SERIAL=emulator-$port

  echo "== starting the emulator ($ANDROID_SERIAL, Android API ${apiLevel} ${imageType} x86_64)" >&2
  "$sdk/emulator/emulator" -avd bb -port "$port" -no-window -no-audio -no-boot-anim \
    -no-snapshot -gpu swiftshader_indirect -accel on > "$work/emulator.log" 2>&1 &
  pid=$!
  booted=
  for _ in $(seq 1 180); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    if [ "$(${adb} shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; then booted=1; break; fi
    sleep 2
  done
  if [ -z "$booted" ]; then
    echo "test-android-emulator: the emulator did not boot; its log:" >&2
    cat "$work/emulator.log" >&2
    exit 1
  fi
  abis=$(${adb} shell getprop ro.product.cpu.abilist | tr -d '\r')
  echo "== booted; ABIs: $abis" >&2
  case ",$abis," in
    *,arm64-v8a,*) ;;
    *) echo "test-android-emulator: the image runs no arm64-v8a programs" >&2; exit 1 ;;
  esac

  status=0
  for k in $(printf '%s\n' "''${!app[@]}" | sort); do
    printf '\n== %s\n' "$k" >&2
    if "''${app[$k]}"/bin/*; then
      echo "ok: $k" >&2
    else
      echo "FAIL: $k" >&2
      status=1
    fi
  done
  exit $status
''
