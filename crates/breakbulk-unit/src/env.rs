//! The environment contract ("Environment contract" in
//! `docs/src/reference/unit-builder.md`).
//!
//! A unit's child process (rustc or a build script) gets an environment built
//! from scratch, in layers:
//!
//! 1. A fixed base: `HOME=/homeless-shelter`, `LC_ALL=C`, `TZ=UTC`,
//!    `SOURCE_DATE_EPOCH=315532800` (nixpkgs' default), plus [`PASSED_BASE`]
//!    copied from the builder's environment when Nix set them. A test
//!    process (a doctest) gets a fresh, empty, writable `HOME` in the
//!    build's temporary directory instead ([`Outer::test_base`]).
//! 2. The env capture (`env.json`) for the unit's package and platform.
//! 3. to 5. The unit's rendered `env`: Cargo's recorded env, then the toolchain
//!    spec's env, then the package override's env, merged at instantiation.
//!
//! A value of layers 3 to 5 replaces the earlier layers' value, or appends
//! to it with a separator when the rendered unit's `envAppend` names it
//! ([`merge_rendered`]): a recorded list-like variable
//! ([`list_separator`]), or a variable a user's env layer gave as a list.
//!
//! Then, as nixpkgs' stdenv does for every build, the unit's own
//! `-frandom-seed` goes at the start of `NIX_CFLAGS_COMPILE`, and a
//! `-ffile-prefix-map` for each path the unit remaps goes at its end
//! ([`CFlags`]).
//!
//! Nothing else from the builder's environment reaches the child: not the
//! derivation's attributes, not the output paths, not `BREAKBULK_UNIT`.
//! Afterwards `NUM_JOBS`, when the unit has it, is replaced with the job
//! count from `NIX_BUILD_CORES`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::Error;

/// The variables of the fixed base that have constant values.
pub const FIXED_BASE: [(&str, &str); 4] = [
    ("HOME", "/homeless-shelter"),
    ("LC_ALL", "C"),
    // setup.sh's default (`setup.sh`, "SOURCE_DATE_EPOCH" in nixpkgs). Env
    // captures drop it, so a package's build stamp overrides it in one place.
    ("SOURCE_DATE_EPOCH", "315532800"),
    ("TZ", "UTC"),
];

/// The variables of the fixed base copied from the builder's environment.
///
/// `NIX_STORE`, `NIX_BUILD_TOP` and `TMPDIR` are what nixpkgs' compiler and
/// linker wrappers accept paths under when a capture sets
/// `NIX_ENFORCE_PURITY=1` (`badPath` in `wrapper-common/utils.bash`). Without
/// `NIX_STORE` the compiler wrapper fails on the unset variable (`set -u`)
/// and the linker wrapper skips its check.
pub const PASSED_BASE: [&str; 4] = ["NIX_BUILD_CORES", "NIX_BUILD_TOP", "NIX_STORE", "TMPDIR"];

/// The built-in separators of list-like variables, by name
/// (`env-separators.json`, which the Nix library reads too): `:` for the
/// search paths setup hooks build with `addToSearchPath`, a space for the
/// flag lists the compiler and linker wrappers (and bindgen) split into
/// words. The names are those a broad capture of common hooks produced
/// (pkg-config, cmake, perl, python3, gettext, gobject-introspection,
/// autotools) and the wrappers' own inputs (`cc-wrapper/add-flags.sh`,
/// `bintools-wrapper/add-flags.sh`, `rust-bindgen-hook.sh`).
fn separators() -> &'static BTreeMap<String, char> {
    static TABLE: std::sync::OnceLock<BTreeMap<String, char>> = std::sync::OnceLock::new();
    TABLE.get_or_init(|| {
        serde_json::from_str(include_str!("env-separators.json"))
            .expect("env-separators.json is a JSON object of one-character strings")
    })
}

/// The separator of a list-like variable from the built-in table, or
/// `None` for any other. The `_FOR_BUILD` and `_FOR_TARGET` forms that
/// setup hooks write for other platform offsets are lists like their base
/// names.
///
/// It decides how Cargo's recorded env (layer 3) and the env captures of a
/// link closure merge with layer 2. A user's env layers say it themselves
/// ([`EnvAppend`]).
pub fn list_separator(name: &str) -> Option<char> {
    let base = name
        .strip_suffix("_FOR_BUILD")
        .or_else(|| name.strip_suffix("_FOR_TARGET"))
        .unwrap_or(name);
    separators().get(base).copied()
}

/// The variables of a rendered env whose value appends to the value of
/// the earlier layers, with the separator to put between them; every other
/// variable replaces it. An env layer's list (`env.X = [ … ]`) appends, a
/// string replaces, the captured value included.
pub type EnvAppend = BTreeMap<String, char>;

/// One variable of a user's env layer (the toolchain spec's, the
/// package's, a test run's): `value` replaces the earlier layers' value,
/// or, with a `sep`, is appended to it with `sep` between them (the
/// setting was a list). Both are strings so that instantiation can fill
/// them in as tokens.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LayerValue {
    pub value: String,
    /// One character, or empty: `value` replaces. Always written, as
    /// instantiation writes it before it knows the value.
    #[serde(default)]
    pub sep: String,
}

impl LayerValue {
    pub fn set(value: impl Into<String>) -> LayerValue {
        LayerValue {
            value: value.into(),
            sep: String::new(),
        }
    }

    pub fn append(value: impl Into<String>, sep: char) -> LayerValue {
        LayerValue {
            value: value.into(),
            sep: sep.to_string(),
        }
    }

    fn sep(&self) -> Option<char> {
        self.sep.chars().next()
    }
}

/// An env layer of [`LayerValue`]s, by variable.
pub type EnvLayer = BTreeMap<String, LayerValue>;

/// Fold the user's env layers (4 and 5, lowest first) over Cargo's
/// recorded env (`values`, with `appends`): a replacing value replaces,
/// and the variable no longer appends to the env capture; an appending one
/// goes after the value there, or, with none, appends to the capture.
pub fn fold_layers(
    values: &BTreeMap<String, String>,
    appends: &EnvAppend,
    layers: &[EnvLayer],
) -> (BTreeMap<String, String>, EnvAppend) {
    let mut values = values.clone();
    let mut appends = appends.clone();
    for layer in layers {
        for (k, v) in layer {
            match (v.sep(), values.get(k)) {
                (None, _) => {
                    appends.remove(k);
                    values.insert(k.clone(), v.value.clone());
                }
                (Some(sep), Some(earlier)) => {
                    let merged = append(sep, earlier, &v.value);
                    values.insert(k.clone(), merged);
                }
                (Some(sep), None) => {
                    appends.insert(k.clone(), sep);
                    values.insert(k.clone(), v.value.clone());
                }
            }
        }
    }
    (values, appends)
}

/// Whether `value` looks like a search path of store paths: what a string
/// replacing a captured value most likely meant to extend.
fn looks_like_list(value: &str) -> bool {
    value.contains(':') && value.contains("/nix/store")
}

/// `earlier` followed by `later`. An empty side is left out, so no empty
/// search-path entry (which would mean the working directory) appears.
pub fn append(sep: char, earlier: &str, later: &str) -> String {
    match (earlier.is_empty(), later.is_empty()) {
        (_, true) => earlier.to_owned(),
        (true, false) => later.to_owned(),
        (false, false) => format!("{earlier}{sep}{later}"),
    }
}

/// Merge a later layer into `env` by the built-in table: its values
/// replace earlier ones, except for list-like variables
/// ([`list_separator`]), which are appended. For layers whose own rules
/// come with them, [`merge_rendered`].
pub fn merge_layer<K, V>(
    env: &mut BTreeMap<String, String>,
    layer: impl IntoIterator<Item = (K, V)>,
) where
    K: Into<String>,
    V: Into<String>,
{
    for (k, v) in layer {
        let (k, v) = (k.into(), v.into());
        let merged = match (list_separator(&k), env.get(&k)) {
            (Some(sep), Some(earlier)) => append(sep, earlier, &v),
            _ => v,
        };
        env.insert(k, merged);
    }
}

/// Merge a rendered env (`values`, with `appends` saying which of them
/// append) over `env`: an appending value goes after the earlier one, any
/// other replaces it. A replaced value that looks like a list of store
/// paths gets a warning, since `env.X = "…"` is easily meant as an append.
pub fn merge_rendered(
    env: &mut BTreeMap<String, String>,
    values: &BTreeMap<String, String>,
    appends: &EnvAppend,
) {
    for (k, v) in values {
        let merged = match (appends.get(k), env.get(k)) {
            (Some(sep), Some(earlier)) => append(*sep, earlier, v),
            (None, Some(earlier)) if earlier != v && looks_like_list(earlier) => {
                eprintln!(
                    "warning: `{k}` replaces the env capture's value, which looks like a list \
                     (`{earlier}`); give the setting as a list (`env.{k} = [ … ]`) to append to it"
                );
                v.clone()
            }
            _ => v.clone(),
        };
        env.insert(k.clone(), merged);
    }
}

/// What a unit adds to C compiler flags, through `NIX_CFLAGS_COMPILE`.
///
/// `NIX_CFLAGS_COMPILE` is read by nixpkgs' cc-wrapper on every compile it
/// wraps, whoever starts the compiler: cc-rs, cmake, make or a plain
/// `Command::new("cc")`, for C, C++ and assembly. It is how stdenv adds its
/// own `-frandom-seed`, and it lives only in the unit's environment, so it
/// changes no other unit and nothing Cargo hashes. cc-rs's own `CFLAGS`
/// family would miss C++ (`CXXFLAGS`), cmake and plain compiler calls.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CFlags {
    /// The value of `-frandom-seed`; `None` adds none.
    pub random_seed: Option<String>,
    /// `(from, to)` pairs for `-ffile-prefix-map=from=to`: the unit's source
    /// views, crate sources and `OUT_DIR`s, with the names Rust remaps them
    /// to.
    pub prefix_maps: Vec<(String, String)>,
}

impl CFlags {
    /// The words added at the end of `NIX_CFLAGS_COMPILE`. A pair containing
    /// whitespace cannot survive the wrapper's word splitting; it is skipped
    /// with a warning.
    pub fn prefix_map_flags(&self) -> Vec<String> {
        self.prefix_maps
            .iter()
            .filter(|(from, to)| {
                let ok = !from.is_empty() && !(from.contains(char::is_whitespace) || to.contains(char::is_whitespace));
                if !ok {
                    eprintln!(
                        "warning: not remapping `{from}` to `{to}` in C flags: the path is empty or contains whitespace"
                    );
                }
                ok
            })
            .map(|(from, to)| format!("-ffile-prefix-map={from}={to}"))
            .collect()
    }

    /// Apply to `env`: the seed first, as `reproducible-builds.sh` puts it
    /// before anything setup hooks add, then the prefix maps last, so they
    /// win over any earlier map of the same path (GCC and Clang use the last
    /// matching option).
    pub fn apply(&self, env: &mut BTreeMap<String, String>) {
        let maps = self.prefix_map_flags();
        if self.random_seed.is_none() && maps.is_empty() {
            return;
        }
        let mut value = env.remove("NIX_CFLAGS_COMPILE").unwrap_or_default();
        if let Some(seed) = &self.random_seed {
            // Setup hooks append with a leading space; a value from a layer
            // that sets the variable outright may have none.
            let sep = if value.is_empty() || value.starts_with(' ') {
                ""
            } else {
                " "
            };
            value = format!(" -frandom-seed={seed}{sep}{value}");
        }
        for m in maps {
            value = append(' ', &value, &m);
        }
        env.insert("NIX_CFLAGS_COMPILE".into(), value);
    }
}

/// What `breakbulk-unit` reads from the environment Nix gave it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outer {
    /// All of the builder's environment. Only [`PASSED_BASE`], the output
    /// paths and the random-seed inputs are used from it.
    pub vars: BTreeMap<String, String>,
}

impl Outer {
    pub fn from_process() -> Outer {
        Outer {
            vars: std::env::vars_os()
                .filter_map(|(k, v)| Some((k.into_string().ok()?, v.into_string().ok()?)))
                .collect(),
        }
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.vars.get(k).map(String::as_str)
    }

    /// The build's temporary directory: `$TMPDIR`, or `/tmp`.
    pub fn tmpdir(&self) -> PathBuf {
        PathBuf::from(
            self.get("TMPDIR")
                .filter(|s| !s.is_empty())
                .unwrap_or("/tmp"),
        )
    }

    /// The path of a derivation output, from the variable Nix names after it.
    pub fn output(&self, name: &str) -> Result<PathBuf, Error> {
        match self.get(name) {
            Some(p) if !p.is_empty() => Ok(PathBuf::from(p)),
            _ => Err(Error::new(format!(
                "the derivation output `{name}` is not set in the environment"
            ))),
        }
    }

    /// The job count for `NUM_JOBS`: `NIX_BUILD_CORES`, where `0` (or an
    /// unset or invalid value) means every available CPU, as in Nix.
    pub fn jobs(&self) -> usize {
        match self
            .get("NIX_BUILD_CORES")
            .and_then(|s| s.parse::<usize>().ok())
        {
            Some(n) if n > 0 => n,
            _ => std::thread::available_parallelism().map_or(1, |n| n.get()),
        }
    }

    /// The home directory of a test process: `home` in the build's
    /// temporary directory, which nothing else uses and which goes away
    /// with the build.
    pub fn test_home(&self) -> PathBuf {
        self.tmpdir().join("home")
    }

    /// Layer 1 of a test process: [`Outer::base`] with `HOME` at
    /// [`Outer::test_home`]. Tests write to their home (caches, config
    /// files) as they do under `cargo test`, where it is the user's; an
    /// empty one reads nothing of the user's. `XDG_*` stay unset, so tools
    /// fall back to directories under `HOME`. Compiles and build-script
    /// runs keep `/homeless-shelter`, so a build that writes to its home
    /// fails.
    pub fn test_base(&self) -> BTreeMap<String, String> {
        let mut env = self.base();
        env.insert("HOME".into(), self.test_home().display().to_string());
        env
    }

    /// Layer 1.
    pub fn base(&self) -> BTreeMap<String, String> {
        let mut env: BTreeMap<String, String> = FIXED_BASE
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        for k in PASSED_BASE {
            if let Some(v) = self.get(k) {
                env.insert(k.to_owned(), v.to_owned());
            }
        }
        env
    }
}

/// Read an env capture: a JSON object whose values are all strings. `path`
/// is the capture's `env.json`, or the capture's output directory holding
/// it.
pub fn read_capture(path: &Path) -> Result<BTreeMap<String, String>, Error> {
    let file = if path.is_dir() {
        path.join("env.json")
    } else {
        path.to_owned()
    };
    let text = std::fs::read_to_string(&file)
        .map_err(|e| Error::new(format!("reading env capture {}: {e}", file.display())))?;
    serde_json::from_str(&text).map_err(|e| {
        Error::new(format!(
            "env capture {} is not a JSON object of strings: {e}",
            file.display()
        ))
    })
}

/// The variables of another package's env capture that a linking unit takes:
/// the library search flags nixpkgs' bintools-wrapper setup
/// hook writes for every library input (`bintoolsWrapper_addLDVars` appends
/// `-L<input>/lib` to `NIX_LDFLAGS${role_post}`). A capture's `inputs` are
/// `buildInputs` of its stdenv, whose role suffix is empty; the
/// `_FOR_BUILD` form holds the library directories of its `nativeInputs`
/// (tools such as cmake or libclang), which are not what dependents link,
/// so it is left out. The linker wrapper turns the flags into `-L`, and
/// adds an rpath for each of those directories that holds a shared library
/// a `-l` names (`ld-wrapper.sh`). Compiler flags, `PATH` and
/// `PKG_CONFIG_PATH` stay with the package's own units.
pub const LINK_VARS: [&str; 1] = ["NIX_LDFLAGS"];

/// Layer 2 of a linking unit: its own capture, then the [`LINK_VARS`] of
/// each of `link_captures`, appended in order. `None` when there is
/// neither.
pub fn capture_layer(
    capture: Option<&str>,
    link_captures: &[String],
) -> Result<Option<BTreeMap<String, String>>, Error> {
    let mut env = capture.map(|p| read_capture(Path::new(p))).transpose()?;
    for p in link_captures {
        let other = read_capture(Path::new(p))?;
        let env = env.get_or_insert_with(BTreeMap::new);
        merge_layer(
            env,
            other
                .into_iter()
                .filter(|(k, v)| LINK_VARS.contains(&k.as_str()) && !v.trim().is_empty()),
        );
    }
    Ok(env)
}

/// Build a child's environment from the layers. `unit_env` is layers 3–5,
/// already merged.
pub fn layered(
    outer: &Outer,
    capture: Option<&BTreeMap<String, String>>,
    unit_env: &BTreeMap<String, String>,
    env_append: &EnvAppend,
    cflags: &CFlags,
) -> BTreeMap<String, String> {
    layered_on(outer.base(), outer, capture, unit_env, env_append, cflags)
}

/// [`layered`] over another layer 1 (`base`), such as
/// [`Outer::test_base`].
pub fn layered_on(
    base: BTreeMap<String, String>,
    outer: &Outer,
    capture: Option<&BTreeMap<String, String>>,
    unit_env: &BTreeMap<String, String>,
    env_append: &EnvAppend,
    cflags: &CFlags,
) -> BTreeMap<String, String> {
    let mut env = base;
    if let Some(c) = capture {
        merge_layer(&mut env, c.iter().map(|(k, v)| (k.as_str(), v.as_str())));
    }
    merge_rendered(&mut env, unit_env, env_append);
    cflags.apply(&mut env);
    if env.contains_key("NUM_JOBS") {
        env.insert("NUM_JOBS".into(), outer.jobs().to_string());
    }
    env
}

#[cfg(test)]
mod tests;
