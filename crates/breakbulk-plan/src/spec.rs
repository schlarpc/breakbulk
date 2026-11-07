//! The toolchain spec's share of planning ("Toolchain presets" and "Path
//! rewriting" in `docs/implementation.md`, decision 33).
//!
//! The spec (`--spec FILE`, JSON) carries the target's extra rustflags, the
//! target linker and the host linker. Spec env never reaches Cargo; it is
//! added per unit by platform at instantiation.
//!
//! - **Rustflags.** Cargo takes rustflags from exactly one source
//!   (`extra_args` in Cargo's `core/compiler/build_context/target_info.rs`):
//!   `CARGO_ENCODED_RUSTFLAGS`, `RUSTFLAGS`, then `target.<triple>.rustflags`
//!   together with every matching `target.'cfg(…)'.rustflags` (used when
//!   their concatenation is non-empty), then `build.rustflags`. Arrays
//!   concatenate only within one key. The planner clears the environment,
//!   so [`ProjectConfig`] reads the project's config files and
//!   [`RustflagsKey::choose`] puts the spec's flags where they join the
//!   project's: under `build.rustflags` when the project uses that and no
//!   target rustflags apply, under `target.<triple>.rustflags` otherwise.
//! - **Linkers.** `target.<triple>.linker` for the target. When the host
//!   triple differs, `target.<host>.linker` for host units (Cargo applies
//!   `target.<host>` to host units while `target-applies-to-host` has its
//!   default). When they are the same triple Cargo gives the target linker
//!   to host units too; [`Prepared::apply`] then rewrites `-C linker=` on host
//!   compiles and `RUSTC_LINKER` on host runs, after checking each carries
//!   exactly the configured target linker.
//! - **Confirmation.** After the trace, [`Prepared::apply`] checks that every
//!   target compile unit carries the spec's rustflags (contiguously, as
//!   configured) and every project rustflag of the chosen source, and the
//!   spec's linker.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use breakbulk_format::{Arg, Plan, Platform, Text, Unit};
use serde::Deserialize;

use crate::{Error, bail};

/// The spec file the Nix side writes.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Spec {
    /// Extra rustflags for target units.
    #[serde(default)]
    pub rustflags: Vec<String>,
    /// The target linker (a store path), or none.
    #[serde(default)]
    pub linker: Option<String>,
    /// The host linker (a store path), or none.
    #[serde(default)]
    pub host_linker: Option<String>,
}

impl Spec {
    pub fn read(path: &str) -> Result<Spec, Error> {
        let text =
            std::fs::read_to_string(path).map_err(|e| Error(format!("reading {path}: {e}")))?;
        serde_json::from_str(&text).map_err(|e| Error(format!("{path}: {e}")))
    }

    pub fn is_empty(&self) -> bool {
        self.rustflags.is_empty() && self.linker.is_none() && self.host_linker.is_none()
    }
}

/// Where the spec's rustflags go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RustflagsKey {
    Build,
    Target,
}

/// The rustflags settings of the project's config files.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectConfig {
    /// `build.rustflags`, merged across files, when set anywhere.
    pub build_rustflags: Option<Vec<String>>,
    /// `target.<key>.rustflags` by key (a triple or `cfg(…)`), merged.
    pub target_rustflags: BTreeMap<String, Vec<String>>,
    /// The `[env]` table's variables, with their `force` flag, merged.
    pub env: BTreeMap<String, bool>,
    /// The files read, in precedence order (lowest first).
    pub files: Vec<PathBuf>,
    /// The rustflags keys (`build`, `target.<key>`) whose value so far is a
    /// string, which a later string replaces instead of extending.
    string_keys: BTreeSet<String>,
}

/// Merge a later (higher-precedence) rustflags value into `old`, as Cargo's
/// `ConfigValue::merge` does (`src/cargo/util/context/config_value.rs`,
/// `merge_helper`): arrays concatenate, lower precedence first; a string
/// replaces a string; a string and an array do not merge.
fn merge_rustflags(
    old: &mut Option<Vec<String>>,
    strings: &mut BTreeSet<String>,
    key: String,
    (new, new_is_string): (Vec<String>, bool),
    what: &str,
) -> Result<(), Error> {
    match old {
        None => *old = Some(new),
        Some(old) => match (strings.contains(&key), new_is_string) {
            (false, false) => old.extend(new),
            (true, true) => *old = new,
            _ => bail!(
                "{what}: `{key}.rustflags` is a string in one config file and an array in another, \
                 which Cargo does not merge"
            ),
        },
    }
    if new_is_string {
        strings.insert(key);
    } else {
        strings.remove(&key);
    }
    Ok(())
}

/// A config string list: a whitespace-separated string or an array of
/// strings (Cargo's `StringList`).
fn string_list(v: &toml::Value, what: &str) -> Result<Vec<String>, Error> {
    match v {
        toml::Value::String(s) => Ok(s.split_whitespace().map(str::to_owned).collect()),
        toml::Value::Array(a) => a
            .iter()
            .map(|x| match x {
                toml::Value::String(s) => Ok(s.clone()),
                _ => Err(Error(format!("{what}: expected a string in the array"))),
            })
            .collect(),
        _ => bail!("{what}: expected a string or an array of strings"),
    }
}

impl ProjectConfig {
    /// Read the config files Cargo reads when started in `cwd`: every
    /// `.cargo/config.toml` (or `.cargo/config`, which wins when both exist)
    /// from `cwd` up to `/`, with their `include`s, and `$CARGO_HOME`'s
    /// (`cargo_home`). Deeper files take precedence; arrays concatenate with
    /// the lower-precedence values first (Cargo's `walk_tree` and
    /// `ConfigValue::merge`). Includes are merged before the including
    /// file (`load_includes`).
    pub fn read(cwd: &Path, cargo_home: Option<&Path>) -> Result<ProjectConfig, Error> {
        let mut dirs: Vec<PathBuf> = cwd.ancestors().map(|d| d.join(".cargo")).collect();
        if let Some(home) = cargo_home
            && !dirs.iter().any(|d| d == home)
        {
            dirs.push(home.to_owned());
        }
        // Lowest precedence first: home, then from `/` down to `cwd`.
        let mut files = Vec::new();
        for dir in dirs.iter().rev() {
            for name in ["config", "config.toml"] {
                let p = dir.join(name);
                if p.is_file() {
                    files.push(p);
                    break;
                }
            }
        }
        let mut cfg = ProjectConfig::default();
        let mut seen = Vec::new();
        for f in &files {
            cfg.load(f, &mut seen)?;
        }
        Ok(cfg)
    }

    fn load(&mut self, path: &Path, seen: &mut Vec<PathBuf>) -> Result<(), Error> {
        if seen.iter().any(|s| s == path) {
            bail!("config `include` cycle at {}", path.display());
        }
        seen.push(path.to_owned());
        let text = std::fs::read_to_string(path)
            .map_err(|e| Error(format!("reading {}: {e}", path.display())))?;
        let table: toml::Table =
            toml::from_str(&text).map_err(|e| Error(format!("{}: {e}", path.display())))?;
        let what = path.display().to_string();
        if let Some(inc) = table.get("include") {
            let dir = path.parent().unwrap_or(Path::new("/"));
            let entries: Vec<(String, bool)> = match inc {
                toml::Value::String(s) => vec![(s.clone(), false)],
                toml::Value::Array(a) => a
                    .iter()
                    .map(|x| match x {
                        toml::Value::String(s) => Ok((s.clone(), false)),
                        toml::Value::Table(t) => {
                            let p = t.get("path").and_then(|p| p.as_str()).ok_or_else(|| {
                                Error(format!("{what}: `include` entry without a `path`"))
                            })?;
                            let optional =
                                t.get("optional").and_then(|o| o.as_bool()).unwrap_or(false);
                            Ok((p.to_owned(), optional))
                        }
                        _ => Err(Error(format!("{what}: malformed `include`"))),
                    })
                    .collect::<Result<_, _>>()?,
                _ => bail!("{what}: malformed `include`"),
            };
            for (rel, optional) in entries {
                let p = dir.join(rel);
                if optional && !p.exists() {
                    continue;
                }
                self.load(&p, seen)?;
            }
        }
        if let Some(b) = table.get("build").and_then(|b| b.get("rustflags")) {
            let v = string_list(b, &format!("{what}: build.rustflags"))?;
            merge_rustflags(
                &mut self.build_rustflags,
                &mut self.string_keys,
                "build".into(),
                (v, b.is_str()),
                &what,
            )?;
        }
        match table.get("env") {
            None => {}
            Some(toml::Value::Table(env)) => {
                for (k, v) in env {
                    // `NAME = "value"`, or `NAME = { value, force, relative }`
                    // (Cargo's `EnvConfigValue`). A deeper file's table
                    // merges into a shallower one's; a string replaces it.
                    let force = match v {
                        toml::Value::String(_) => false,
                        toml::Value::Table(t) => match t.get("force") {
                            Some(toml::Value::Boolean(f)) => *f,
                            None => self.env.get(k).copied().unwrap_or(false),
                            Some(_) => bail!("{what}: env.{k}.force: expected a boolean"),
                        },
                        _ => bail!("{what}: env.{k}: expected a string or a table"),
                    };
                    self.env.insert(k.clone(), force);
                }
            }
            Some(_) => bail!("{what}: `env` is not a table"),
        }
        if let Some(toml::Value::Table(targets)) = table.get("target") {
            for (key, t) in targets {
                if let Some(r) = t.get("rustflags") {
                    let v = string_list(r, &format!("{what}: target.{key}.rustflags"))?;
                    let mut old = self.target_rustflags.remove(key);
                    merge_rustflags(
                        &mut old,
                        &mut self.string_keys,
                        format!("target.{key}"),
                        (v, r.is_str()),
                        &what,
                    )?;
                    self.target_rustflags
                        .insert(key.clone(), old.unwrap_or_default());
                }
            }
        }
        self.files.push(path.to_owned());
        seen.pop();
        Ok(())
    }

    /// The project's target rustflags for `triple`: `target.<triple>` then
    /// every matching `target.'cfg(…)'` key, as Cargo concatenates them.
    pub fn target_flags(&self, triple: &str, cfg: &[CfgValue]) -> Result<Vec<String>, Error> {
        let mut flags = self
            .target_rustflags
            .get(triple)
            .cloned()
            .unwrap_or_default();
        for (key, v) in &self.target_rustflags {
            if let Some(inner) = key.strip_prefix("cfg(").and_then(|k| k.strip_suffix(')')) {
                let expr = CfgExpr::parse(inner)
                    .map_err(|e| Error(format!("target.'{key}': cannot parse: {e}")))?;
                if expr.matches(cfg) {
                    flags.extend(v.iter().cloned());
                }
            }
        }
        Ok(flags)
    }
}

impl ProjectConfig {
    /// The `[env]` variables Cargo sets on the processes it starts, when its
    /// own environment has the variables `cargo_env`: every one with
    /// `force`, and the others only when Cargo's environment lacks them
    /// (`GlobalContext::env_config`; the Cargo book's `[env]` section).
    pub fn applied_env(&self, cargo_env: &BTreeSet<String>) -> BTreeSet<String> {
        self.env
            .iter()
            .filter(|(k, force)| **force || !cargo_env.contains(*k))
            .map(|(k, _)| k.clone())
            .collect()
    }
}

impl RustflagsKey {
    /// Where the spec's flags join the project's, and the project's flags
    /// Cargo will use (to confirm in the trace).
    pub fn choose(
        project: &ProjectConfig,
        triple: &str,
        cfg: &[CfgValue],
    ) -> Result<(RustflagsKey, Vec<String>), Error> {
        let target = project.target_flags(triple, cfg)?;
        Ok(if !target.is_empty() {
            (RustflagsKey::Target, target)
        } else if let Some(b) = &project.build_rustflags {
            (RustflagsKey::Build, b.clone())
        } else {
            (RustflagsKey::Target, Vec::new())
        })
    }
}

fn toml_str(s: &str) -> String {
    serde_json::to_string(s).expect("strings serialize")
}

fn toml_list(v: &[String]) -> String {
    format!(
        "[{}]",
        v.iter().map(|s| toml_str(s)).collect::<Vec<_>>().join(", ")
    )
}

/// The `--config` file for a spec.
pub fn config_text(spec: &Spec, key: RustflagsKey, target: &str, host: &str) -> String {
    let mut target_table = Vec::new();
    let mut out = String::new();
    if !spec.rustflags.is_empty() {
        match key {
            RustflagsKey::Build => {
                out.push_str(&format!(
                    "[build]\nrustflags = {}\n",
                    toml_list(&spec.rustflags)
                ));
            }
            RustflagsKey::Target => {
                target_table.push(format!("rustflags = {}", toml_list(&spec.rustflags)));
            }
        }
    }
    if let Some(l) = &spec.linker {
        target_table.push(format!("linker = {}", toml_str(l)));
    }
    if !target_table.is_empty() {
        out.push_str(&format!(
            "[target.{}]\n{}\n",
            toml_str(target),
            target_table.join("\n")
        ));
    }
    if host != target
        && let Some(l) = &spec.host_linker
    {
        out.push_str(&format!(
            "[target.{}]\nlinker = {}\n",
            toml_str(host),
            toml_str(l)
        ));
    }
    out
}

/// The spec's `--config` as Cargo's environment configuration, for the dev
/// shell ("Dev shell" in `docs/implementation.md`): local Cargo given these
/// variables applies the spec as the planner's `--config` does. Cargo
/// appends an environment list to the config files' list for the same key
/// (`GlobalContext::get_cv_with_env`, "Lists are always merged"), as it
/// appends a `--config` list, so the project's own flags stay first.
///
/// An environment list is split on whitespace, so a flag containing
/// whitespace cannot be passed this way; such flags are returned as
/// warnings instead.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct CargoEnv {
    pub env: BTreeMap<String, String>,
    pub warnings: Vec<String>,
}

/// `CARGO_TARGET_<TRIPLE>_<KEY>`: the triple uppercased, with `-` and `.`
/// as `_` (Cargo's `ConfigKey::as_env_key`).
pub fn target_env_var(triple: &str, key: &str) -> String {
    let t: String = triple
        .chars()
        .map(|c| match c {
            '-' | '.' => '_',
            c => c.to_ascii_uppercase(),
        })
        .collect();
    format!("CARGO_TARGET_{t}_{key}")
}

impl Prepared {
    pub fn cargo_env(&self) -> CargoEnv {
        let mut out = CargoEnv::default();
        if !self.spec.rustflags.is_empty() {
            let var = match self.key {
                RustflagsKey::Build => "CARGO_BUILD_RUSTFLAGS".to_owned(),
                RustflagsKey::Target => target_env_var(&self.target, "RUSTFLAGS"),
            };
            let (ok, bad): (Vec<&String>, Vec<&String>) = self
                .spec
                .rustflags
                .iter()
                .partition(|f| !f.contains(char::is_whitespace));
            for f in bad {
                out.warnings.push(format!(
                    "the rustflag `{f}` contains whitespace; {var} cannot carry it"
                ));
            }
            let joined: Vec<&str> = ok.iter().map(|s| s.as_str()).collect();
            out.env.insert(var, joined.join(" "));
        }
        if let Some(l) = &self.spec.linker {
            out.env
                .insert(target_env_var(&self.target, "LINKER"), l.clone());
        }
        if let Some(l) = &self.spec.host_linker {
            if self.host != self.target {
                out.env
                    .insert(target_env_var(&self.host, "LINKER"), l.clone());
            } else if self.spec.linker.as_ref() != Some(l) {
                out.warnings.push(format!(
                    "the host linker {l} differs from the target linker on the same triple; \
                     local Cargo gives build scripts the target linker"
                ));
            }
        }
        out
    }
}

/// One line of `rustc --print cfg`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CfgValue {
    Name(String),
    KeyPair(String, String),
}

impl CfgValue {
    pub fn parse_print_cfg(text: &str) -> Vec<CfgValue> {
        text.lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .map(|l| match l.split_once('=') {
                Some((k, v)) => CfgValue::KeyPair(k.to_owned(), v.trim_matches('"').to_owned()),
                None => CfgValue::Name(l.to_owned()),
            })
            .collect()
    }
}

/// `rustc --print cfg --target <triple>`.
pub fn target_cfg(rustc: &str, triple: &str) -> Result<Vec<CfgValue>, Error> {
    let out = Command::new(rustc)
        .args(["--print", "cfg", "--target", triple])
        .env_clear()
        .envs(std::env::var_os("PATH").map(|p| ("PATH", p)))
        .output()
        .map_err(|e| Error(format!("running {rustc} --print cfg: {e}")))?;
    if !out.status.success() {
        bail!(
            "{rustc} --print cfg --target {triple} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(CfgValue::parse_print_cfg(&String::from_utf8_lossy(
        &out.stdout,
    )))
}

/// A `cfg(…)` predicate, as in Cargo's `cargo-platform` crate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CfgExpr {
    Not(Box<CfgExpr>),
    All(Vec<CfgExpr>),
    Any(Vec<CfgExpr>),
    Value(CfgValue),
    True,
    False,
}

impl CfgExpr {
    pub fn parse(s: &str) -> Result<CfgExpr, String> {
        let toks = tokenize(s)?;
        let mut p = Parser { toks, pos: 0 };
        let e = p.expr()?;
        if p.pos != p.toks.len() {
            return Err(format!("unexpected `{}`", p.toks[p.pos]));
        }
        Ok(e)
    }

    pub fn matches(&self, cfg: &[CfgValue]) -> bool {
        match self {
            CfgExpr::Not(e) => !e.matches(cfg),
            CfgExpr::All(es) => es.iter().all(|e| e.matches(cfg)),
            CfgExpr::Any(es) => es.iter().any(|e| e.matches(cfg)),
            CfgExpr::Value(v) => cfg.contains(v),
            CfgExpr::True => true,
            CfgExpr::False => false,
        }
    }
}

fn tokenize(s: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    let mut chars = s.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
        } else if "(),=".contains(c) {
            out.push(c.to_string());
            chars.next();
        } else if c == '"' {
            chars.next();
            let mut v = String::from("\"");
            loop {
                match chars.next() {
                    Some('"') => break,
                    Some(c) => v.push(c),
                    None => return Err("unterminated string".into()),
                }
            }
            out.push(v);
        } else if c.is_alphanumeric() || c == '_' {
            let mut v = String::new();
            while let Some(&c) = chars.peek() {
                if c.is_alphanumeric() || c == '_' || c == '#' {
                    v.push(c);
                    chars.next();
                } else {
                    break;
                }
            }
            out.push(v.strip_prefix("r#").unwrap_or(&v).to_owned());
        } else {
            return Err(format!("unexpected character `{c}`"));
        }
    }
    Ok(out)
}

struct Parser {
    toks: Vec<String>,
    pos: usize,
}

impl Parser {
    fn next(&mut self) -> Option<String> {
        let t = self.toks.get(self.pos).cloned();
        self.pos += 1;
        t
    }

    fn peek(&self) -> Option<&str> {
        self.toks.get(self.pos).map(String::as_str)
    }

    fn expect(&mut self, t: &str) -> Result<(), String> {
        match self.next() {
            Some(x) if x == t => Ok(()),
            Some(x) => Err(format!("expected `{t}`, found `{x}`")),
            None => Err(format!("expected `{t}`")),
        }
    }

    fn list(&mut self) -> Result<Vec<CfgExpr>, String> {
        self.expect("(")?;
        let mut v = Vec::new();
        while self.peek() != Some(")") {
            v.push(self.expr()?);
            if self.peek() == Some(",") {
                self.next();
            } else {
                break;
            }
        }
        self.expect(")")?;
        Ok(v)
    }

    fn expr(&mut self) -> Result<CfgExpr, String> {
        let name = self.next().ok_or("unexpected end")?;
        if name.starts_with('"') || "(),=".contains(name.as_str()) {
            return Err(format!("unexpected `{name}`"));
        }
        match (name.as_str(), self.peek()) {
            ("all", Some("(")) => Ok(CfgExpr::All(self.list()?)),
            ("any", Some("(")) => Ok(CfgExpr::Any(self.list()?)),
            ("not", Some("(")) => {
                let mut v = self.list()?;
                if v.len() != 1 {
                    return Err("not() takes one predicate".into());
                }
                Ok(CfgExpr::Not(Box::new(v.remove(0))))
            }
            (_, Some("=")) => {
                self.next();
                let v = self.next().ok_or("expected a string")?;
                let v = v.strip_prefix('"').ok_or("expected a string")?;
                Ok(CfgExpr::Value(CfgValue::KeyPair(name, v.to_owned())))
            }
            ("true", _) => Ok(CfgExpr::True),
            ("false", _) => Ok(CfgExpr::False),
            _ => Ok(CfgExpr::Value(CfgValue::Name(name))),
        }
    }
}

/// What planning needs from the spec, prepared before the trace.
#[derive(Clone, Debug)]
pub struct Prepared {
    pub spec: Spec,
    pub key: RustflagsKey,
    /// The host triple, for the host linker.
    pub host: String,
    /// The target triple.
    pub target: String,
    /// The project's rustflags of the chosen source.
    pub project_flags: Vec<String>,
    /// The generated `--config` file.
    pub config: PathBuf,
}

/// Choose the key, write the `--config` file into `scratch`.
pub fn prepare(
    spec: Spec,
    cwd: &Path,
    rustc: &str,
    target: &str,
    host: &str,
    scratch: &Path,
) -> Result<Prepared, Error> {
    let project = ProjectConfig::read(cwd, None)?;
    let cfg = if project
        .target_rustflags
        .keys()
        .any(|k| k.starts_with("cfg("))
    {
        target_cfg(rustc, target)?
    } else {
        Vec::new()
    };
    let (key, project_flags) = RustflagsKey::choose(&project, target, &cfg)?;
    let config = scratch.join("breakbulk-spec.toml");
    std::fs::write(&config, config_text(&spec, key, target, host))
        .map_err(|e| Error(format!("writing {}: {e}", config.display())))?;
    Ok(Prepared {
        spec,
        key,
        host: host.to_owned(),
        target: target.to_owned(),
        project_flags,
        config,
    })
}

/// The host triple from `rustc -vV`.
pub fn host_triple(rustc: &str) -> Result<String, Error> {
    let out = Command::new(rustc)
        .arg("-vV")
        .env_clear()
        .envs(std::env::var_os("PATH").map(|p| ("PATH", p)))
        .output()
        .map_err(|e| Error(format!("running {rustc} -vV: {e}")))?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .find_map(|l| l.strip_prefix("host: "))
        .map(|h| h.trim().to_owned())
        .ok_or_else(|| Error(format!("`{rustc} -vV` names no host")))
}

/// [`prepare`] for the planner's options, when they name a spec.
pub fn prepare_for(opts: &crate::trace::Options) -> Result<Option<Prepared>, Error> {
    let Some(path) = &opts.spec else {
        return Ok(None);
    };
    let spec = Spec::read(path)?;
    if spec.is_empty() {
        return Ok(None);
    }
    let scratch = Path::new(&opts.scratch);
    std::fs::create_dir_all(scratch)
        .map_err(|e| Error(format!("creating {}: {e}", scratch.display())))?;
    let root = Path::new(&opts.skeleton);
    let cwd = if opts.workspace.is_empty() {
        root.to_owned()
    } else {
        root.join(&opts.workspace)
    };
    let host = host_triple(&opts.rustc)?;
    prepare(spec, &cwd, &opts.rustc, &opts.target, &host, scratch).map(Some)
}

fn literal(a: &Arg) -> Option<&str> {
    match a {
        Arg::Literal(s) => Some(s),
        _ => None,
    }
}

/// The positions of `-C linker=…` (two arguments or one) in `args`, with
/// the value.
fn linker_args(args: &[Arg]) -> Vec<(usize, bool, String)> {
    let mut out = Vec::new();
    for (i, a) in args.iter().enumerate() {
        let Some(s) = literal(a) else { continue };
        if s == "-C"
            && let Some(v) = args
                .get(i + 1)
                .and_then(literal)
                .and_then(|n| n.strip_prefix("linker="))
        {
            out.push((i + 1, false, v.to_owned()));
        } else if let Some(v) = s.strip_prefix("-Clinker=") {
            out.push((i, true, v.to_owned()));
        }
    }
    out
}

fn contains_run(hay: &[&str], needle: &[String]) -> bool {
    needle.is_empty()
        || hay
            .windows(needle.len())
            .any(|w| w.iter().zip(needle).all(|(a, b)| *a == b))
}

impl Prepared {
    /// Confirm the spec arrived, and rewrite host linkers for same-triple
    /// targets.
    pub fn apply(&self, plan: &mut Plan) -> Result<(), Error> {
        let same = plan.host == plan.target;
        let rewrite = match (&self.spec.linker, &self.spec.host_linker) {
            (Some(t), Some(h)) if same && t != h => Some((t.clone(), h.clone())),
            _ => None,
        };
        let mut problems = Vec::new();
        for (id, unit) in plan.units.iter_mut() {
            match unit {
                Unit::Compile(c) if c.platform == Platform::Target => {
                    let lits: Vec<&str> = c.args.iter().filter_map(literal).collect();
                    if !contains_run(&lits, &self.spec.rustflags) {
                        problems.push(format!(
                            "{id} ({}): the spec's rustflags {:?} did not arrive",
                            c.krate.name, self.spec.rustflags
                        ));
                    }
                    let missing: Vec<&String> = self
                        .project_flags
                        .iter()
                        .filter(|f| !lits.contains(&f.as_str()))
                        .collect();
                    if !missing.is_empty() {
                        problems.push(format!(
                            "{id} ({}): the project's rustflags {missing:?} did not arrive",
                            c.krate.name
                        ));
                    }
                    if let Some(l) = &self.spec.linker {
                        let got = linker_args(&c.args);
                        if got.len() != 1 || &got[0].2 != l {
                            problems.push(format!(
                                "{id} ({}): expected one `-C linker={l}`, found {:?}",
                                c.krate.name,
                                got.iter().map(|g| &g.2).collect::<Vec<_>>()
                            ));
                        }
                    }
                }
                Unit::Compile(c) => {
                    let Some((t, h)) = &rewrite else { continue };
                    let got = linker_args(&c.args);
                    match got.as_slice() {
                        [(i, joined, v)] if v == t => {
                            c.args[*i] = Arg::Literal(if *joined {
                                format!("-Clinker={h}")
                            } else {
                                format!("linker={h}")
                            });
                        }
                        _ => problems.push(format!(
                            "host unit {id} ({}): expected exactly one `-C linker={t}` (the \
                             target linker Cargo gives host units on a same-triple target), \
                             found {:?}",
                            c.krate.name,
                            got.iter().map(|g| &g.2).collect::<Vec<_>>()
                        )),
                    }
                }
                Unit::Run(r) if r.platform == Platform::Host => {
                    let Some((t, h)) = &rewrite else { continue };
                    match r.env.get("RUSTC_LINKER") {
                        Some(Text::Literal(v)) if v == t => {
                            r.env
                                .insert("RUSTC_LINKER".into(), Text::Literal(h.clone()));
                        }
                        other => problems.push(format!(
                            "host run {id}: expected RUSTC_LINKER={t}, found {other:?}"
                        )),
                    }
                }
                Unit::Run(_) => {}
            }
        }
        if !problems.is_empty() {
            bail!(
                "the toolchain spec did not reach the traced units as configured (Cargo {}, \
                 rustflags under {}):\n  {}",
                plan.cargo,
                match self.key {
                    RustflagsKey::Build => "build.rustflags".to_owned(),
                    RustflagsKey::Target => format!("target.{}.rustflags", plan.target),
                },
                problems.join("\n  ")
            );
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfgs() -> Vec<CfgValue> {
        CfgValue::parse_print_cfg(
            "debug_assertions\npanic=\"unwind\"\ntarget_arch=\"x86_64\"\ntarget_os=\"linux\"\nunix\n",
        )
    }

    #[test]
    fn cfg_expressions() {
        let c = cfgs();
        let m = |s: &str| CfgExpr::parse(s).unwrap().matches(&c);
        assert!(m("unix"));
        assert!(!m("windows"));
        assert!(m("target_os = \"linux\""));
        assert!(m("all(unix, target_arch=\"x86_64\")"));
        assert!(!m("all(unix, target_arch=\"aarch64\")"));
        assert!(m("any(windows, unix)"));
        assert!(m("not(windows)"));
        assert!(m("true"));
        assert!(!m("false"));
        assert!(m("all()"));
        assert!(!m("any()"));
        assert!(CfgExpr::parse("all(unix").is_err());
        assert!(CfgExpr::parse("not(unix, windows)").is_err());
    }

    fn dir(files: &[(&str, &str)]) -> PathBuf {
        static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let d = std::env::temp_dir().join(format!(
            "bb-spec-{}-{}",
            std::process::id(),
            N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&d);
        for (p, text) in files {
            let p = d.join(p);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
        d
    }

    fn read(d: &Path, sub: &str) -> ProjectConfig {
        // Only files under `d` (the temp dir's ancestors have none in a
        // sandbox; outside one they are filtered out here).
        let mut c = ProjectConfig::read(&d.join(sub), None).unwrap();
        let keep: Vec<PathBuf> = c
            .files
            .iter()
            .filter(|f| f.starts_with(d))
            .cloned()
            .collect();
        assert_eq!(
            keep, c.files,
            "unexpected config files outside the test dir"
        );
        c.files = keep;
        c
    }

    #[test]
    fn cargo_env_for_the_dev_shell() {
        let prepared = |key, host: &str| Prepared {
            spec: Spec {
                rustflags: vec![
                    "-C".into(),
                    "target-feature=+crt-static".into(),
                    "a b".into(),
                ],
                linker: Some("/nix/store/x-cc/bin/cc".into()),
                host_linker: Some("/nix/store/y-cc/bin/cc".into()),
            },
            key,
            host: host.into(),
            target: "aarch64-unknown-linux-musl".into(),
            project_flags: vec![],
            config: PathBuf::new(),
        };
        let e = prepared(RustflagsKey::Target, "x86_64-unknown-linux-gnu").cargo_env();
        assert_eq!(
            e.env,
            BTreeMap::from([
                (
                    "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER".into(),
                    "/nix/store/x-cc/bin/cc".into()
                ),
                (
                    "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS".into(),
                    "-C target-feature=+crt-static".into()
                ),
                (
                    "CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER".into(),
                    "/nix/store/y-cc/bin/cc".into()
                ),
            ])
        );
        assert_eq!(e.warnings.len(), 1, "{:?}", e.warnings);
        let e = prepared(RustflagsKey::Build, "aarch64-unknown-linux-musl").cargo_env();
        assert_eq!(
            e.env["CARGO_BUILD_RUSTFLAGS"],
            "-C target-feature=+crt-static"
        );
        // Same triple, different host linker: not expressible.
        assert_eq!(e.warnings.len(), 2, "{:?}", e.warnings);
        assert_eq!(
            target_env_var("thumbv7em-none-eabihf.json", "LINKER"),
            "CARGO_TARGET_THUMBV7EM_NONE_EABIHF_JSON_LINKER"
        );
    }

    #[test]
    fn env_table() {
        let d = dir(&[
            (
                ".cargo/config.toml",
                "[env]\nPLAIN = \"a\"\nFORCED = { value = \"b\", force = true }\n\
                 PATH = \"/nope\"\nHOME = { value = \"/h\", force = true }\n\
                 LATER = { value = \"x\", force = true }\n",
            ),
            (
                "ws/.cargo/config.toml",
                "[env]\nREL = { value = \"d\", relative = true }\n\
                 FORCED = { value = \"c\" }\nLATER = \"y\"\n",
            ),
        ]);
        let c = read(&d, "ws");
        assert_eq!(
            c.env,
            BTreeMap::from([
                ("FORCED".into(), true),
                ("HOME".into(), true),
                ("LATER".into(), false),
                ("PATH".into(), false),
                ("PLAIN".into(), false),
                ("REL".into(), false),
            ])
        );
        let cargo_env: BTreeSet<String> = ["PATH", "HOME", "LATER"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(
            c.applied_env(&cargo_env).into_iter().collect::<Vec<_>>(),
            ["FORCED", "HOME", "PLAIN", "REL"]
        );
    }

    #[test]
    fn key_choice() {
        let t = "x86_64-unknown-linux-gnu";
        // Arrays concatenate, the shallower file's first.
        let d = dir(&[
            (".cargo/config.toml", "[build]\nrustflags = [\"-Ca\"]\n"),
            (
                "ws/.cargo/config.toml",
                "[build]\nrustflags = [\"--cfg\", \"x\"]\n",
            ),
        ]);
        let c = read(&d, "ws");
        assert_eq!(
            RustflagsKey::choose(&c, t, &cfgs()).unwrap(),
            (
                RustflagsKey::Build,
                vec!["-Ca".into(), "--cfg".into(), "x".into()]
            )
        );

        // A deeper string replaces a string (observed with Cargo 1.99).
        let d = dir(&[
            (
                ".cargo/config.toml",
                "[build]\nrustflags = \"-C a  -C b\"\n[target.x86_64-unknown-linux-gnu]\nrustflags = \"--cfg t1\"\n",
            ),
            (
                "ws/.cargo/config.toml",
                "[build]\nrustflags = \"--cfg x\"\n[target.x86_64-unknown-linux-gnu]\nrustflags = \"--cfg t2\"\n",
            ),
        ]);
        let c = read(&d, "ws");
        assert_eq!(c.build_rustflags, Some(vec!["--cfg".into(), "x".into()]));
        assert_eq!(
            RustflagsKey::choose(&c, t, &cfgs()).unwrap(),
            (RustflagsKey::Target, vec!["--cfg".into(), "t2".into()])
        );

        // A string and an array do not merge; Cargo fails too.
        let d = dir(&[
            (".cargo/config.toml", "[build]\nrustflags = \"-Ca\"\n"),
            ("ws/.cargo/config.toml", "[build]\nrustflags = [\"-Cb\"]\n"),
        ]);
        let e = ProjectConfig::read(&d.join("ws"), None).unwrap_err();
        assert!(e.0.contains("string in one config file"), "{e}");

        let d = dir(&[(
            ".cargo/config.toml",
            "[build]\nrustflags = [\"-Cb\"]\n[target.'cfg(windows)']\nrustflags = [\"-Cw\"]\n",
        )]);
        let c = read(&d, "");
        assert_eq!(
            RustflagsKey::choose(&c, t, &cfgs()).unwrap().0,
            RustflagsKey::Build,
            "a cfg key that does not match leaves build.rustflags in effect"
        );

        let d = dir(&[(
            ".cargo/config.toml",
            "[build]\nrustflags = [\"-Cb\"]\n[target.'cfg(unix)']\nrustflags = [\"-Cu\"]\n",
        )]);
        let c = read(&d, "");
        assert_eq!(
            RustflagsKey::choose(&c, t, &cfgs()).unwrap(),
            (RustflagsKey::Target, vec!["-Cu".into()])
        );

        // An empty target list is "no target flags" to Cargo.
        let d = dir(&[(
            ".cargo/config.toml",
            "[build]\nrustflags = [\"-Cb\"]\n[target.x86_64-unknown-linux-gnu]\nrustflags = []\n",
        )]);
        assert_eq!(
            RustflagsKey::choose(&read(&d, ""), t, &cfgs()).unwrap().0,
            RustflagsKey::Build
        );

        // `.cargo/config` wins over `.cargo/config.toml`; includes load
        // before the including file.
        let d = dir(&[
            (
                ".cargo/config",
                "include = [\"more.toml\"]\n[build]\nrustflags = [\"-C2\"]\n",
            ),
            (
                ".cargo/config.toml",
                "[target.x86_64-unknown-linux-gnu]\nrustflags = [\"-Cno\"]\n",
            ),
            (".cargo/more.toml", "[build]\nrustflags = [\"-C1\"]\n"),
        ]);
        assert_eq!(
            RustflagsKey::choose(&read(&d, ""), t, &cfgs()).unwrap(),
            (RustflagsKey::Build, vec!["-C1".into(), "-C2".into()])
        );

        let d = dir(&[("x/.keep", "")]);
        assert_eq!(
            RustflagsKey::choose(&read(&d, "x"), t, &cfgs()).unwrap(),
            (RustflagsKey::Target, vec![])
        );
    }

    #[test]
    fn config_file() {
        let spec = Spec {
            rustflags: vec!["-C".into(), "target-feature=+crt-static".into()],
            linker: Some("/nix/store/x-cc/bin/cc".into()),
            host_linker: Some("/nix/store/y-cc/bin/cc".into()),
        };
        let t = config_text(
            &spec,
            RustflagsKey::Target,
            "aarch64-unknown-linux-gnu",
            "x86_64-unknown-linux-gnu",
        );
        let v: toml::Table = toml::from_str(&t).unwrap();
        assert_eq!(
            v["target"]["aarch64-unknown-linux-gnu"]["rustflags"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            v["target"]["x86_64-unknown-linux-gnu"]["linker"].as_str(),
            Some("/nix/store/y-cc/bin/cc")
        );
        let t = config_text(
            &spec,
            RustflagsKey::Build,
            "x86_64-unknown-linux-gnu",
            "x86_64-unknown-linux-gnu",
        );
        let v: toml::Table = toml::from_str(&t).unwrap();
        assert!(v["build"]["rustflags"].is_array());
        assert_eq!(
            v["target"]["x86_64-unknown-linux-gnu"]["linker"].as_str(),
            Some("/nix/store/x-cc/bin/cc"),
            "same triple: only the target linker is configured; host units are rewritten"
        );
    }

    #[test]
    fn linker_positions() {
        let args = vec![
            Arg::Literal("-C".into()),
            Arg::Literal("linker=/a".into()),
            Arg::Literal("-Clinker=/b".into()),
        ];
        assert_eq!(
            linker_args(&args),
            vec![(1, false, "/a".into()), (2, true, "/b".into())]
        );
    }
}
