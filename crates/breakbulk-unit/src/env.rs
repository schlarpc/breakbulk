//! The environment contract ("Unit execution" in `docs/implementation.md`).
//!
//! A unit's child process (rustc or a build script) gets an environment built
//! from scratch, in layers:
//!
//! 1. A fixed base: `HOME=/homeless-shelter`, `LC_ALL=C`, `TZ=UTC`,
//!    `SOURCE_DATE_EPOCH=315532800` (nixpkgs' default), plus [`PASSED_BASE`]
//!    copied from the builder's environment when Nix set them.
//! 2. The env capture (`env.json`) for the unit's package and platform.
//! 3. to 5. The unit's rendered `env`: Cargo's recorded env, then the toolchain
//!    spec's env, then the package override's env, merged at instantiation
//!    with [`merge_layer`].
//!
//! Later layers win, except for list-like variables ([`list_separator`]),
//! where a later layer's value is appended to the earlier one.
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
/// `NIX_STORE` every store path counts as impure, and the linker wrapper
/// drops `-L/nix/store/…` arguments.
pub const PASSED_BASE: [&str; 4] = ["NIX_BUILD_CORES", "NIX_BUILD_TOP", "NIX_STORE", "TMPDIR"];

/// Search-path variables: `:`-separated lists that setup hooks build with
/// `addToSearchPath`. The names are those a broad capture of common hooks
/// produced (spike C: pkg-config, cmake, perl, python3, gettext,
/// gobject-introspection, autotools).
const SEARCH_PATHS: [&str; 11] = [
    "ACLOCAL_PATH",
    "CMAKE_INCLUDE_PATH",
    "CMAKE_LIBRARY_PATH",
    "GETTEXTDATADIRS",
    "GI_TYPELIB_PATH",
    "NIXPKGS_CMAKE_PREFIX_PATH",
    "PATH",
    "PERL5LIB",
    "PKG_CONFIG_PATH",
    "PYTHONPATH",
    "XDG_DATA_DIRS",
];

/// Flag variables: space-separated lists that the compiler and linker
/// wrappers (and bindgen) split into words. The `NIX_*` names are the
/// wrappers' inputs (`cc-wrapper/add-flags.sh`, `bintools-wrapper/add-flags.sh`);
/// `BINDGEN_EXTRA_CLANG_ARGS` is filled by `rust-bindgen-hook.sh`.
const FLAG_LISTS: [&str; 7] = [
    "BINDGEN_EXTRA_CLANG_ARGS",
    "NIX_CFLAGS_COMPILE",
    "NIX_CFLAGS_COMPILE_BEFORE",
    "NIX_CFLAGS_LINK",
    "NIX_LDFLAGS",
    "NIX_LDFLAGS_AFTER",
    "NIX_LDFLAGS_BEFORE",
];

/// The separator of a list-like variable, or `None` when later layers
/// replace it. The `_FOR_BUILD` and `_FOR_TARGET` forms that setup hooks
/// write for other platform offsets are lists like their base names.
pub fn list_separator(name: &str) -> Option<char> {
    let base = name
        .strip_suffix("_FOR_BUILD")
        .or_else(|| name.strip_suffix("_FOR_TARGET"))
        .unwrap_or(name);
    if SEARCH_PATHS.contains(&base) {
        Some(':')
    } else if FLAG_LISTS.contains(&base) {
        Some(' ')
    } else {
        None
    }
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

/// Merge a later layer into `env`: its values replace earlier ones, except
/// for list-like variables, which are appended.
///
/// Instantiation uses this to merge layers 3 to 5, and `breakbulk-unit` to
/// put those over layers 1 and 2.
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

/// The variables of another package's env capture that a linking unit takes
/// (decision 107): the library search flags nixpkgs' bintools-wrapper setup
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
    cflags: &CFlags,
) -> BTreeMap<String, String> {
    let mut env = outer.base();
    if let Some(c) = capture {
        merge_layer(&mut env, c.iter().map(|(k, v)| (k.as_str(), v.as_str())));
    }
    merge_layer(
        &mut env,
        unit_env.iter().map(|(k, v)| (k.as_str(), v.as_str())),
    );
    cflags.apply(&mut env);
    if env.contains_key("NUM_JOBS") {
        env.insert("NUM_JOBS".into(), outer.jobs().to_string());
    }
    env
}

#[cfg(test)]
mod tests;
