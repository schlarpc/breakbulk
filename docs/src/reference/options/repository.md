<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->

# Repository-wide options

Settings for the whole repository.

## `ca`

Content-address post-link stages, checks and test runs, so that an
unchanged input does not re-run them\. Needs Nix’s ` ca-derivations `
experimental feature in the evaluator and the daemon\. ` null ` turns
it on exactly when the evaluator has ` dynamic-derivations ` (which
needs ` ca-derivations ` too), and off otherwise: Nix code cannot
tell whether ` ca-derivations ` is on, and without it a
content-addressed derivation is an error that cannot be caught\.



*Type:*
null or boolean



*Default:*

```nix
null
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `gitHashes`



NAR hashes of git sources, keyed by the full ` Cargo.lock ` source
string\. Optional: with a hash, the fetch is fixed-output and a
binary cache can serve it; without one, every fresh machine clones
the source during evaluation\. The hash is that of the fetched tree
(` builtins.fetchGit `’s ` narHash `), not crane’s ` outputHashes `\.



*Type:*
attribute set of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "git+https://github.com/me/serde?rev=abc#abc0123" = "sha256-…";
}
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `gitSubdirs`



Where a crate lives inside a git source, keyed by source string or
URL, then by crate name\. Skips the walk over the tree’s
` Cargo.toml ` files\.



*Type:*
attribute set of attribute set of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  "https://github.com/me/repo" = {
    mycrate = "crates/mycrate";
  };
}
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `gitSubmodules`



Per git URL: whether to fetch submodules\. Cargo checks out
submodules of git dependencies, so the default is true\.



*Type:*
attribute set of boolean



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `gitTrees`



Use a local tree instead of fetching a git source\. Keyed by the
` Cargo.lock ` source string or by URL\.



*Type:*
attribute set of absolute path



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `mode`



How unit derivations reach Nix\. ` ifd `: breakbulk-instantiate writes
units\.json, which Nix imports (import-from-derivation)\. ` dynamic `:
an outer derivation writes the unit derivations through Nix’s
` builder-rpc-v0 ` interface and products reach them with
` builtins.outputOf ` (needs Nix 2\.36 or later with the
` dynamic-derivations ` and ` ca-derivations ` experimental features)\.
` auto ` picks ` dynamic ` when the evaluator has ` builtins.outputOf `
and is Nix 2\.36 or later, and ` ifd ` otherwise\. A daemon or builder
older than the evaluator fails with Nix’s own “missing system
features” error naming ` builder-rpc-v0 `; set ` ifd ` then\. Unit
derivations are identical in both modes; products are not (they are
resolved at build time in ` dynamic `), so teams that mix Nix versions
should pin the mode\.

In ` ifd `, evaluating another system’s outputs builds its plans, which
needs a builder for that system: ` nix flake check --all-systems ` and
` nix flake show --all-systems ` fail on a Linux machine for darwin
outputs (“Required system”)\. Plain ` nix flake check ` and ` nix flake show ` evaluate only the current system and are unaffected, and
` dynamic ` evaluates every system without builders\. With ` ifd `, list
only the systems you can build on (the common ` nix-systems/default `
includes darwin)\.



*Type:*
one of “auto”, “ifd”, “dynamic”



*Default:*

```nix
"auto"
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `registries`



Alternative registries, by name\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `registries.<name>.dl`



Download URL template, as in the registry’s ` config.json `
(` {crate} `, ` {version} `, ` {prefix} `, ` {lowerprefix} `,
` {sha256-checksum} `)\. ` Cargo.lock ` records only the index,
and reading ` config.json ` would need a fetch during
evaluation\.



*Type:*
string



*Example:*

```nix
"https://my-registry.example/api/v1/crates/{crate}/{version}/download"
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `registries.<name>.index`



The registry’s index URL as it appears in ` Cargo.lock `
(with or without the ` registry+ ` prefix; sparse registries
keep ` sparse+ `)\.



*Type:*
string



*Example:*

```nix
"sparse+https://my-registry.example/index/"
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `strictSources`



Fail a build-script run that succeeds while declaring a
` rerun-if-changed ` path missing from its sandbox\. When false, such
paths are warnings that name the option to add them to\.
` packages.<name>.strictSources ` overrides it per package\.



*Type:*
boolean



*Default:*

```nix
false
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `sysDefaults.enable`



Define breakbulk’s curated settings for common ` -sys ` crates
(seeded from nixpkgs’ ` defaultCrateOverrides `) in
` sysDefaults.packages `\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



## `sysDefaults.packages`



Default settings for a package, by crate name: a function of the
package’s lockfile entry (` { name, version, ... } `) that returns
settings with the options of ` packages.<name> `\. They are the
lowest layer; ` packages.<name> ` settings add to them (lists
concatenate, env attributes merge)\.

They name nixpkgs libraries, so they apply only where a package
set exists: host units always (the build machine’s), target units
only when ` targets.<triple>.packageSet ` exists (or the target is
the native one)\. On other targets (msvc, wasm32-unknown-unknown)
those crates build their bundled copies\.

The curated entries are defined at ` mkDefault ` priority, so a
plain definition replaces one: ` null ` turns it off, a function
replaces it\. They are: ` alsa-sys `, ` atk-sys `, ` aws-lc-sys `, ` cairo-rs `, ` cairo-sys-rs `, ` capnp-rpc `, ` cargo `, ` curl-sys `, ` dbus `, ` evdev-sys `, ` expat-sys `, ` foundationdb `, ` foundationdb-sys `, ` freetype-sys `, ` fuser `, ` gdk-pixbuf `, ` gdk-pixbuf-sys `, ` gdk-sys `, ` gdk4-sys `, ` gdkx11-sys `, ` gio-sys `, ` glib-sys `, ` gobject-sys `, ` graphene-sys `, ` gsk4-sys `, ` gtk-sys `, ` gtk4-sys `, ` javascriptcore-rs-sys `, ` libdbus-sys `, ` libgit2-sys `, ` libseat-sys `, ` libsqlite3-sys `, ` libssh2-sys `, ` libudev-sys `, ` libz-sys `, ` nettle-sys `, ` openssl `, ` openssl-sys `, ` opentelemetry-proto `, ` pam-sys `, ` pango-sys `, ` pangocairo-sys `, ` pq-sys `, ` prost-wkt-types `, ` rdkafka-sys `, ` rink `, ` sequoia-guide `, ` sequoia-ipc `, ` sequoia-openpgp `, ` sequoia-openpgp-ffi `, ` sequoia-sq `, ` sequoia-store `, ` sequoia-tool `, ` servo-fontconfig-sys `, ` soup3-sys `, ` thrussh-libsodium `, ` tonic-reflection `, ` webkit2gtk-sys `, ` xcb `, ` zstd-sys `\.



*Type:*
attribute set of (null or (function that evaluates to a(n) (submodule)))



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  libsqlite3-sys = null;  # no curated inputs
  aws-lc-sys = { version, ... }: { inputs = p: [ p.aws-lc ]; };
}

```

*Declared by:*
 - [lib/modules/top\.nix](https://github.com/schlarpc/breakbulk/blob/main/lib/modules/top.nix)



