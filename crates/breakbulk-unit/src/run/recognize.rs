//! Hints for build-script failures that common crates cause in the sandbox
//! (pkg-config, cc, libclang, OpenSSL, protoc, CMake missing), and the
//! summary of the `rerun-if-env-changed` variables the script left unset.
//!
//! What to recognize is data ([`Table`]): the repository's
//! `sysDefaults.buildScriptHints`, which the run names as a file
//! (`hints.buildScriptHints`), read only after a failure. So a change to
//! the table rebuilds build-script runs, not compiles, and a user can add
//! to it. Only the matching is code.
//!
//! A recognizer fires only with both the crate's own error text in the
//! script's output and evidence that the crate ran (its fingerprint). It
//! adds a hint quoting the line it matched. The variables it covers are
//! then counted rather than listed; every other unset variable goes on one
//! line.
//!
//! Two general rules follow, for any crate: a line that says a program was
//! not found (`notFound`) and names a known tool (`tools`) suggests the
//! package that provides it, and a line that shows the script downloading
//! (`network`, `downloaders`) says the sandbox has no network.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::Deserialize;

/// `sysDefaults.buildScriptHints`, as the Nix side writes it.
///
/// Patterns: `*` matches any text, `{}` any non-empty text, which a hint
/// can name as `{0}` (at most one per pattern). Variable patterns also
/// match after a `HOST_` or `TARGET_` prefix, as the crates read
/// `HOST_PKG_CONFIG`, `TARGET_CC` and the like. In a hint, `{opt}` is the
/// package's option prefix (`packages.<name>`).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Table {
    /// By the crate name the summary of covered variables names.
    #[serde(default)]
    pub recognizers: BTreeMap<String, Recognizer>,
    /// What a line says when a program was not found.
    #[serde(default)]
    pub not_found: Vec<String>,
    /// Programs build scripts run, by the name they run, and the nixpkgs
    /// attribute that provides each.
    #[serde(default)]
    pub tools: BTreeMap<String, String>,
    /// The hint for a tool not found: `{tool}` and `{attr}` name it.
    #[serde(default)]
    pub tool_hint: String,
    /// Lowercased text of lines that show a build script downloading or
    /// failing to reach the network.
    #[serde(default)]
    pub network: Vec<String>,
    /// Programs whose name, as a word outside a `cargo:` directive, shows
    /// a download.
    #[serde(default)]
    pub downloaders: Vec<String>,
    /// The hint for a download.
    #[serde(default)]
    pub network_hint: String,
}

/// One crate's failure.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Recognizer {
    /// What the entry is for; documentation only.
    #[serde(default)]
    pub about: Option<String>,
    /// Evidence that the crate ran.
    #[serde(default)]
    pub fingerprint: Fingerprint,
    /// Error lines and their hints, in order; the first pattern a line
    /// matches decides its hint.
    #[serde(default)]
    pub errors: Vec<ErrorRule>,
    /// The variables the crate declares, which are normally left unset.
    #[serde(default)]
    pub covers: Vec<String>,
}

/// Either is enough.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fingerprint {
    /// `rerun-if-env-changed` variables, set or not.
    #[serde(default)]
    pub vars: Vec<String>,
    /// Lines of stdout or stderr.
    #[serde(default)]
    pub lines: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorRule {
    pub pattern: String,
    pub hint: String,
}

impl Table {
    /// The table in the file `path`.
    pub fn read(path: &Path) -> Result<Table, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// The tool of [`Table::tools`] a not-found line names, with its
    /// attribute: as a whole word, quoted, at the end of a path, or before
    /// a `:` (as shells name it). A bare word is not enough: "make sure",
    /// "go to".
    fn named_tool(&self, line: &str) -> Option<(&str, &str)> {
        if !self.not_found.iter().any(|m| line.contains(m.as_str())) {
            return None;
        }
        let name_char = |c: char| c.is_ascii_alphanumeric() || "-_.+".contains(c);
        self.tools
            .iter()
            .find(|(tool, _)| {
                line.match_indices(tool.as_str()).any(|(i, _)| {
                    let before = line[..i].chars().next_back();
                    let after = line[i + tool.len()..].chars().next();
                    !before.is_some_and(name_char)
                        && !after.is_some_and(name_char)
                        && (before.is_some_and(|c| "`'\"/".contains(c))
                            || after.is_some_and(|c| "`'\":".contains(c)))
                })
            })
            .map(|(t, a)| (t.as_str(), a.as_str()))
    }

    /// Whether `line` shows the script downloading: [`Table::network`], or
    /// a downloader as a word outside a `cargo:` directive
    /// (`rustc-link-lib=curl`).
    fn downloads(&self, line: &str) -> bool {
        let lower = line.to_lowercase();
        if self.network.iter().any(|n| lower.contains(n.as_str())) {
            return true;
        }
        if lower.starts_with("cargo:") {
            return false;
        }
        let name_char = |c: char| c.is_ascii_alphanumeric() || "-_".contains(c);
        self.downloaders.iter().any(|t| {
            lower.match_indices(t.as_str()).any(|(i, _)| {
                !lower[..i].chars().next_back().is_some_and(name_char)
                    && !lower[i + t.len()..].chars().next().is_some_and(name_char)
            })
        })
    }
}

/// Matches `pattern` against `text`, returning the `{}` capture (empty
/// without one), or `None`.
fn glob(pattern: &str, text: &str) -> Option<String> {
    fn go<'t>(p: &str, t: &'t str, cap: &mut Option<&'t str>) -> bool {
        if let Some(rest) = p.strip_prefix('*') {
            return (0..=t.len())
                .filter(|&i| t.is_char_boundary(i))
                .any(|i| go(rest, &t[i..], cap));
        }
        if let Some(rest) = p.strip_prefix("{}") {
            return (1..=t.len()).filter(|&i| t.is_char_boundary(i)).any(|i| {
                *cap = Some(&t[..i]);
                go(rest, &t[i..], cap)
            });
        }
        match (p.chars().next(), t.chars().next()) {
            (None, None) => true,
            (Some(a), Some(b)) if a == b => go(&p[a.len_utf8()..], &t[b.len_utf8()..], cap),
            _ => false,
        }
    }
    let mut cap = None;
    go(pattern, text, &mut cap).then(|| cap.unwrap_or_default().to_owned())
}

fn var_matches(pattern: &str, var: &str) -> bool {
    std::iter::once(var)
        .chain(
            ["HOST_", "TARGET_"]
                .iter()
                .filter_map(|p| var.strip_prefix(p)),
        )
        .any(|v| glob(pattern, v).is_some())
}

/// How much of a matched line a hint quotes.
const QUOTE_CHARS: usize = 160;

fn quote(line: &str) -> String {
    match line.char_indices().nth(QUOTE_CHARS) {
        Some((i, _)) => format!("{}…", &line[..i]),
        None => line.to_owned(),
    }
}

/// The hints for a failed run: one per recognized failure, then one per
/// tool not found and one for a download (the general rules), then the
/// unset `unset` variables (in the order declared), summarized for each
/// recognizer that fired and listed on one line otherwise.
///
/// `declared` are the run's `rerun-if-env-changed` variables, `lines` its
/// stdout and stderr, and `opt` the package's option prefix.
pub fn hints<'a>(
    table: &Table,
    opt: &str,
    declared: &[String],
    unset: &[&str],
    lines: impl Iterator<Item = &'a str> + Clone,
) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    let mut covered = BTreeSet::new();
    let mut recognized = BTreeSet::new();
    let mut push = |out: &mut Vec<String>, hint: String, line: &str| {
        if seen.insert(hint.clone()) {
            out.push(format!(
                "{hint}\n      (the build script printed: {})",
                quote(line)
            ));
        }
    };
    for (crate_name, r) in &table.recognizers {
        let f = &r.fingerprint;
        let ran = f
            .vars
            .iter()
            .any(|p| declared.iter().any(|v| var_matches(p, v)))
            || f.lines
                .iter()
                .any(|p| lines.clone().any(|l| glob(p, l.trim()).is_some()));
        if !ran {
            continue;
        }
        let mut fired = false;
        for line in lines.clone().map(str::trim) {
            let Some((hint, cap)) = r
                .errors
                .iter()
                .find_map(|e| glob(&e.pattern, line).map(|c| (&e.hint, c)))
            else {
                continue;
            };
            fired = true;
            recognized.insert(line);
            push(
                &mut out,
                hint.replace("{0}", &cap).replace("{opt}", opt),
                line,
            );
        }
        if !fired {
            continue;
        }
        let mine: Vec<&str> = unset
            .iter()
            .copied()
            .filter(|v| !covered.contains(v) && r.covers.iter().any(|p| var_matches(p, v)))
            .collect();
        if !mine.is_empty() {
            // Only the patterns that matched, each variable counted under
            // its first: listing all of them reads as a list of the
            // variables, longer than the count.
            let first = |v: &&str| r.covers.iter().find(|p| var_matches(p, v));
            let matched: BTreeSet<&String> = mine.iter().filter_map(first).collect();
            let patterns = r
                .covers
                .iter()
                .filter(|p| matched.contains(p))
                .map(|p| format!("`{p}`"))
                .collect::<Vec<_>>()
                .join(", ");
            let n = mine.len();
            let (s, they) = if n == 1 {
                ("", "it is")
            } else {
                ("s", "they are")
            };
            out.push(format!(
                "({n} unset variable{s} of the `{crate_name}` crate omitted, matching {patterns}; \
                 {they} normally left unset)"
            ));
            covered.extend(mine);
        }
    }
    for line in lines.clone().map(str::trim) {
        if recognized.contains(line) {
            continue;
        }
        if let Some((tool, attr)) = table.named_tool(line) {
            push(
                &mut out,
                table
                    .tool_hint
                    .replace("{tool}", tool)
                    .replace("{attr}", attr)
                    .replace("{opt}", opt),
                line,
            );
        }
    }
    if let Some(line) = lines.clone().map(str::trim).find(|l| table.downloads(l)) {
        push(&mut out, table.network_hint.replace("{opt}", opt), line);
    }
    let rest: Vec<&str> = unset
        .iter()
        .copied()
        .filter(|v| !covered.contains(v))
        .collect();
    match rest.as_slice() {
        [] => {}
        [v] => out.push(format!(
            "the build script reads `{v}` (`rerun-if-env-changed`), which is not set; \
             set it with `{opt}.env.{v}` if the script needs it"
        )),
        vs => out.push(format!(
            "the build script reads these unset variables (`rerun-if-env-changed`): {}; \
             set any it needs with `{opt}.env.<NAME>`",
            vs.iter()
                .map(|v| format!("`{v}`"))
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glob_captures() {
        assert_eq!(glob("a*b", "axxb").as_deref(), Some(""));
        assert_eq!(glob("a*b", "axxc"), None);
        assert_eq!(
            glob(
                "*tool \"{}\"*",
                r#"error: failed to find tool "cc": No such file"#
            )
            .as_deref(),
            Some("cc")
        );
        assert_eq!(glob("x{}", "x"), None);
        assert!(var_matches("PKG_CONFIG*", "HOST_PKG_CONFIG_PATH"));
        assert!(var_matches("*_NO_PKG_CONFIG", "LIBSPA_NO_PKG_CONFIG"));
        assert!(!var_matches("CC", "CCACHE"));
        assert!(var_matches("CC", "TARGET_CC"));
        assert!(var_matches("CC_*", "CC_x86_64-unknown-linux-gnu"));
    }
}
