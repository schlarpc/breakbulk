# Link flags outside `NIX_LDFLAGS` (decision 129)

Question: a unit that links takes only `NIX_LDFLAGS` from the env captures
of the other packages in its link closure (decision 107,
`LINK_VARS` in `crates/breakbulk-unit/src/env.rs`). Do nixpkgs setup hooks
or wrapper features put flags that a dependent's link needs anywhere else
(`NIX_CFLAGS_LINK`, `NIX_LDFLAGS_BEFORE`, `NIX_LDFLAGS_AFTER`,
`NIX_LDFLAGS_FOR_TARGET`, `NIX_CXXSTDLIB_LINK`, `LIBRARY_PATH`, rpath
handling)?

Answer: no. In the pinned nixpkgs, no setup hook of a library writes link
flags anywhere but `NIX_LDFLAGS${role_post}`. The other variables are set
only by a package for its own build, or by the compiler and linker
wrappers themselves. No change to breakbulk. Confidence: high for setup
hooks in nixpkgs' tree (exhaustive grep below); setup hooks outside
nixpkgs (overlays, other flakes) are not covered.

Source: nixpkgs `1d060086d60cb76a40cf37109f979d88a5bd6396` (the flake.lock
pin), searched in `/nix/store/…-source` with grep.

## Method

1. Every `.sh` file that names `NIX_CFLAGS_LINK`, `NIX_LDFLAGS_BEFORE`,
   `NIX_LDFLAGS_AFTER` or any `NIX_LDFLAGS_FOR_*`:
   `grep -rln --include=*.sh -E 'NIX_CFLAGS_LINK|NIX_LDFLAGS_BEFORE|NIX_LDFLAGS_AFTER|NIX_LDFLAGS_FOR'`.
2. Every `.nix` file that names them, then only those that also define a
   setup hook (`setupHook`, `makeSetupHook`, `nix-support/setup-hook`,
   `role_post`, `addEnvHooks`), so that inline hooks are covered too.
3. Every setup-hook file (`*setup-hook*`, `*hook*.sh`, 285 files) that
   names `NIX_CFLAGS_LINK` or `NIX_LDFLAGS`, and every one that writes
   `NIX_CFLAGS_COMPILE` (cc-wrapper passes compile flags to link
   commands too, so `-L`/`-l` there would matter).
4. `LIBRARY_PATH` (gcc reads it as `-L`) and plain `LDFLAGS` in any `.sh`.

## Findings

### Only the wrappers read the other variables

The only `.sh` files naming `NIX_CFLAGS_LINK`, `NIX_LDFLAGS_BEFORE`,
`NIX_LDFLAGS_AFTER` or `NIX_LDFLAGS_FOR_*` are the wrappers:
`pkgs/build-support/cc-wrapper/{add-flags.sh,cc-wrapper.sh}`,
`pkgs/build-support/bintools-wrapper/{add-flags.sh,ld-wrapper.sh}` and
`pkgs/by-name/ma/makeBinaryWrapper/make-binary-wrapper.sh`. They read
them; nothing in a setup hook writes them.

`NIX_CXXSTDLIB_LINK` is filled by `cc-wrapper/add-flags.sh` from the
wrapper's own `nix-support/libcxx-ldflags` and added to `NIX_CFLAGS_LINK`
in `cc-wrapper.sh` when linking C++. It is the wrapper's, so every unit
already has it through its own stdenv.

### `NIX_CFLAGS_LINK` and `NIX_LDFLAGS_BEFORE` are per-package

About 80 derivations (in 54 files) set `NIX_CFLAGS_LINK` (one, `libiodbc`, sets
`NIX_LDFLAGS_BEFORE`), all as a derivation attribute or in a build phase
of their own derivation: Perl XS modules (`-L${zlib}/lib -lz`, …),
`sqlite` (`-lm` in `preConfigure`), `tor`/`zfs` (`-lgcc_s`), `gzip`
(`-no-pie`), `zed-editor` (`-fuse-ld=lld`). None of these reaches a
dependent's build. The stdenv adapters (`useMoldLinker`, `useGoldLinker`,
`useWildLinker`, the static adapters in `pkgs/stdenv/adapters.nix`) set
it on every derivation of the adapted stdenv, which includes breakbulk's
captures of that stdenv; each unit already keeps every `NIX_*` variable
of its own capture (`lib/env-capture.nix`).

`androidndk-pkgs.nix` writes `NIX_LDFLAGS_${suffixSalt} += -pie` into its
own wrapper's `nix-support` (a wrapper extension, not a library hook).

### Library setup hooks write `NIX_LDFLAGS`

Hooks that add link flags for dependents, and the variable they use:

| Hook | Adds | Variable | Platforms where it applies |
|---|---|---|---|
| `bintools-wrapper/setup-hook.sh` (`bintoolsWrapper_addLDVars`) | `-L<dep>/lib`, `-L<dep>/lib64` for every dependency, propagated ones included | `NIX_LDFLAGS${role_post}` | all |
| `libiconv/setup-hook.sh` | `-liconv` | `NIX_LDFLAGS${role_post}` | where `libiconv` is GNU libiconv (Darwin); on glibc, musl and wasilibc `libiconv` is `libcIconv`, without the hook |
| `gettext/gettext-setup-hook.sh` | `-lintl` | `NIX_LDFLAGS${role_post}` | `gettextNeedsLdflags`: not glibc and not musl (Darwin, BSDs) |
| `memorymapping/setup-hook.sh` | `-lmemorymapping` (and `-include fmemopen.h`) | `NIX_LDFLAGS` | Darwin-only library |
| NetBSD `compat`, `fts`; FreeBSD `compat` | `-lnbcompat`, `-lfts`, `-legacy` | `NIX_LDFLAGS${role_post}` | BSD bootstrap |
| Darwin `Csu` | `-L@out@/lib` | `NIX_LDFLAGS${role_post}` | Darwin |
| `apple-sdk` `add-private-frameworks.sh` | `-F…/PrivateFrameworks` | `NIX_LDFLAGS` | Darwin |
| `camlidl` (inline `setupHook`) | `-L …/camlidl` | `NIX_LDFLAGS` | OCaml |
| `separate-debug-info.sh` | `--compress-debug-sections=zlib` | `NIX_LDFLAGS` | the derivation's own build (`separateDebugInfo`); captures do not set it |
| `stdenv/generic/setup.sh` `_addRpathPrefix` | `-rpath $out/lib` | `NIX_LDFLAGS` | the derivation's own output; captures set `NIX_NO_SELF_RPATH` |

The only ones a Rust `-sys` crate's library would bring are `libiconv`
(`iconv` users on Darwin) and `gettext` (`gettext-sys` on Darwin): both
in `NIX_LDFLAGS`, which linking units already take. On Linux (glibc or
musl), the only hook that adds link flags for a library input is
bintools-wrapper's `-L`.

`_FOR_BUILD` and `_FOR_TARGET`: `role_post` is `_FOR_BUILD` for a
capture's `nativeInputs` (tools, which dependents do not link) and
`_FOR_TARGET` only for dependencies at the target offset (compiler
builds); a capture's library inputs are `buildInputs`, so `role_post` is
empty. Leaving those out stays right.

Setup hooks that write `NIX_CFLAGS_COMPILE` add `-isystem`, `-I`, `-D`
and `-include` only (FreeBSD/NetBSD/OpenBSD compat, Qt, shiboken6,
memorymapping): nothing link-relevant. No setup hook sets `LIBRARY_PATH`
or `LDFLAGS`.

### Rpaths

The rpath for a library input comes from `ld-wrapper.sh`, which adds
`-rpath` for each `-L` directory holding a shared library that a `-l`
names. It reads the `-L` flags from `NIX_LDFLAGS` (and the command line),
so it already sees the other captures' directories. There is no separate
propagated-rpath channel.

## Conclusion

Link steps keep taking only `NIX_LDFLAGS` from other packages' captures.
Taking `NIX_CFLAGS_LINK` or `NIX_LDFLAGS_BEFORE`/`_AFTER` too would add
nothing for any library in nixpkgs. If a user's own setup hook writes one
of them, the flags reach that package's own units only; a package override
(`packages.<name>.env`) on the linking package is the workaround.
