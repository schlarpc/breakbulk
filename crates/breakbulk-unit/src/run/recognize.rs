//! Hints for build-script failures that common crates cause in the sandbox
//! (pkg-config, cc, libclang, OpenSSL, protoc, CMake missing), and the
//! summary of the `rerun-if-env-changed` variables the script left unset.
//!
//! A recognizer fires only with both the crate's own error text in the
//! script's output and evidence that the crate ran (its fingerprint). It
//! adds a hint quoting the line it matched. The variables it covers are
//! then counted rather than listed; every other unset variable goes on one
//! line.
//!
//! Two general rules follow, for any crate: a line that says a program was
//! not found and names a known tool ([`TOOLS`]) suggests the package that
//! provides it, and a line that shows the script downloading
//! ([`NETWORK`]) says the sandbox has no network.
//!
//! The tables are not user-extensible: recognizers run inside the unit
//! builder, so a user table would be an input of every run unit.

use std::collections::BTreeSet;

/// One crate's failure. Patterns: `*` matches any text, `{}` any non-empty
/// text, which the hint can name as `{0}` (at most one per pattern).
/// Variable patterns also match after a `HOST_` or `TARGET_` prefix, as the
/// crates read `HOST_PKG_CONFIG`, `TARGET_CC` and the like.
struct Recognizer {
    /// What the summary of covered variables names.
    crate_name: &'static str,
    /// Evidence that the crate ran: a declared variable or an output line.
    fingerprint: &'static [Evidence],
    /// Error lines and their hints, in order; the first pattern a line
    /// matches decides its hint. `{opt}` in a hint is the package's option
    /// prefix (`packages.<name>`).
    errors: &'static [(&'static str, &'static str)],
    /// The variables the crate declares, which are normally left unset.
    covers: &'static [&'static str],
}

enum Evidence {
    /// A `rerun-if-env-changed` variable, set or not.
    Var(&'static str),
    /// A line of stdout or stderr.
    Line(&'static str),
}

const PKG_CONFIG_VARS: &[&str] = &["PKG_CONFIG*", "*_NO_PKG_CONFIG"];

/// The variables cc-rs declares: its tools and flags (each also with a
/// `_<target>` suffix), its switches, and those the compilers it runs read.
const CC_VARS: &[&str] = &[
    "CC",
    "CC_*",
    "CFLAGS",
    "CFLAGS_*",
    "CXX",
    "CXX_*",
    "CXXFLAGS",
    "CXXFLAGS_*",
    "CXXSTDLIB*",
    "AR",
    "AR_*",
    "ARFLAGS",
    "ARFLAGS_*",
    "RANLIB",
    "RANLIB_*",
    "RANLIBFLAGS",
    "RANLIBFLAGS_*",
    "CRATE_CC_NO_DEFAULTS",
    "CROSS_COMPILE",
    "CPATH",
    "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH",
    "OBJC_INCLUDE_PATH",
    "OBJCPLUS_INCLUDE_PATH",
    "COMPILER_PATH",
    "GCC_EXEC_PREFIX",
    "CCC_OVERRIDE_OPTIONS",
    "CLANG_NO_DEFAULT_CONFIG",
];

const LIBCLANG_VARS: &[&str] = &[
    "BINDGEN_EXTRA_CLANG_ARGS*",
    "LIBCLANG_PATH",
    "LIBCLANG_STATIC_PATH",
    "LLVM_CONFIG_PATH",
];

/// openssl-sys reads each of its variables plain and with the target as a
/// prefix (`X86_64_UNKNOWN_LINUX_GNU_OPENSSL_DIR`).
const OPENSSL_VARS: &[&str] = &["*OPENSSL_*"];

const RECOGNIZERS: &[Recognizer] = &[
    // pkg-config-rs: `Error::Command` with `NotFound` (0.3.25 on), and its
    // older `Failed to run` form; `Error::ProbeFailure`, and pkg-config's own
    // message, which it quotes (and which older versions print alone).
    Recognizer {
        crate_name: "pkg-config",
        fingerprint: &[
            Evidence::Var("PKG_CONFIG*"),
            Evidence::Var("*_NO_PKG_CONFIG"),
        ],
        errors: &[
            (
                "*The pkg-config command could not be found.*",
                "`pkg-config` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.pkg-config ];`",
            ),
            (
                "*Failed to run `*pkg-config*`: No such file or directory*",
                "`pkg-config` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.pkg-config ];`",
            ),
            (
                "*The system library `{}` required by crate*was not found*",
                "pkg-config found no `{0}.pc`; add the package that provides `{0}` to `{opt}.inputs` (`inputs = p: [ p.<package> ];`)",
            ),
            (
                "*Package {} was not found in the pkg-config search path*",
                "pkg-config found no `{0}.pc`; add the package that provides `{0}` to `{opt}.inputs` (`inputs = p: [ p.<package> ];`)",
            ),
        ],
        covers: PKG_CONFIG_VARS,
    },
    // cc-rs: `ToolNotFound`, as later versions word it and as 1.0 to 1.2 did.
    Recognizer {
        crate_name: "cc",
        fingerprint: &[
            Evidence::Var("CC*"),
            Evidence::Var("CFLAGS*"),
            Evidence::Var("CXX*"),
        ],
        errors: &[
            (
                "*failed to find tool \"{}\"*",
                "the `cc` crate could not run `{0}`; add the package that provides it to `{opt}.nativeInputs`",
            ),
            (
                "*Failed to find tool. Is `{}` installed?*",
                "the `cc` crate could not run `{0}`; add the package that provides it to `{opt}.nativeInputs`",
            ),
        ],
        covers: CC_VARS,
    },
    // bindgen's `Unable to find libclang` panic (with the `runtime` feature)
    // and clang-sys's own search error, which it wraps; both print
    // clang-sys's `llvm-config` warning first when it is missing. bindgen
    // can panic before it declares any variable, and the error text is
    // its own, so it is a fingerprint too.
    Recognizer {
        crate_name: "bindgen/clang-sys",
        fingerprint: &[
            Evidence::Var("BINDGEN_EXTRA_CLANG_ARGS*"),
            Evidence::Var("LIBCLANG_PATH"),
            Evidence::Line("*could not execute `llvm-config` one or more times*"),
            Evidence::Line("*Unable to find libclang*"),
            Evidence::Line("*couldn't find any valid shared libraries matching:*`LIBCLANG_PATH`*"),
        ],
        errors: &[
            (
                "*Unable to find libclang*",
                "libclang is not in the sandbox; add `{opt}.nativeInputs = p: [ p.rustPlatform.bindgenHook ];`",
            ),
            (
                "*couldn't find any valid shared libraries matching:*`LIBCLANG_PATH`*",
                "libclang is not in the sandbox; add `{opt}.nativeInputs = p: [ p.rustPlatform.bindgenHook ];`",
            ),
        ],
        covers: LIBCLANG_VARS,
    },
    // openssl-sys's `find_openssl_dir`, printed to stderr and as a warning.
    Recognizer {
        crate_name: "openssl-sys",
        fingerprint: &[Evidence::Var("*OPENSSL_*")],
        errors: &[(
            "*Could not find directory of OpenSSL installation*",
            "OpenSSL is not in the sandbox; add `{opt}.inputs = p: [ p.openssl ];` and `{opt}.nativeInputs = p: [ p.pkg-config ];`",
        )],
        covers: OPENSSL_VARS,
    },
    // prost-build declares no variables; its message links its own docs.
    Recognizer {
        crate_name: "prost-build",
        fingerprint: &[Evidence::Line("*docs.rs/prost-build/#sourcing-protoc*")],
        errors: &[(
            "*Could not find `protoc`*",
            "`protoc` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.protobuf ];`",
        )],
        covers: &[],
    },
    // cmake-rs prints each variable it reads as `NAME = value` and declares
    // none; `run`'s `NotFound` and exit-127 messages.
    Recognizer {
        crate_name: "cmake",
        fingerprint: &[Evidence::Line("*CMAKE* = *")],
        errors: &[
            (
                "*is `cmake` not installed?*",
                "`cmake` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.cmake ];`",
            ),
            (
                "*is `{}` not installed?*",
                "the `cmake` crate could not run `{0}`; add the package that provides it to `{opt}.nativeInputs`",
            ),
        ],
        covers: &[],
    },
];

/// What a line says when a program was not found: Rust's `io::Error`
/// (`Debug` and `Display`), C's `strerror`, bash and dash.
const NOT_FOUND: &[&str] = &[
    "NotFound",
    "os error 2",
    "No such file or directory",
    "command not found",
    ": not found",
];

/// Programs build scripts run, by the name they run, and the nixpkgs
/// attribute that provides each.
const TOOLS: &[(&str, &str)] = &[
    ("autoconf", "autoconf"),
    ("autoreconf", "autoconf"),
    ("automake", "automake"),
    ("bison", "bison"),
    ("clang", "clang"),
    ("cmake", "cmake"),
    ("curl", "curl"),
    ("flex", "flex"),
    ("gcc", "gcc"),
    ("git", "git"),
    ("glslc", "shaderc"),
    ("go", "go"),
    ("gperf", "gperf"),
    ("libtool", "libtool"),
    ("m4", "m4"),
    ("make", "gnumake"),
    ("meson", "meson"),
    ("nasm", "nasm"),
    ("ninja", "ninja"),
    ("node", "nodejs"),
    ("npm", "nodejs"),
    ("patch", "patch"),
    ("perl", "perl"),
    ("pkg-config", "pkg-config"),
    ("protoc", "protobuf"),
    ("python", "python3"),
    ("python3", "python3"),
    ("swig", "swig"),
    ("tar", "gnutar"),
    ("unzip", "unzip"),
    ("wget", "wget"),
    ("yasm", "yasm"),
];

/// The tool of [`TOOLS`] a not-found line names, with its attribute: as a
/// whole word, quoted, at the end of a path, or before a `:` (as shells
/// name it). A bare word is not enough: "make sure", "go to".
fn named_tool(line: &str) -> Option<(&'static str, &'static str)> {
    if !NOT_FOUND.iter().any(|m| line.contains(m)) {
        return None;
    }
    let name_char = |c: char| c.is_ascii_alphanumeric() || "-_.+".contains(c);
    TOOLS.iter().copied().find(|(tool, _)| {
        line.match_indices(tool).any(|(i, _)| {
            let before = line[..i].chars().next_back();
            let after = line[i + tool.len()..].chars().next();
            !before.is_some_and(name_char)
                && !after.is_some_and(name_char)
                && (before.is_some_and(|c| "`'\"/".contains(c))
                    || after.is_some_and(|c| "`'\":".contains(c)))
        })
    })
}

/// Lowercased text of lines that show a build script downloading or
/// failing to reach the network.
const NETWORK: &[&str] = &[
    "downloading http",
    "failed to download",
    "could not resolve host",
    "temporary failure in name resolution",
    "name or service not known",
    "failed to lookup address information",
    "dns error",
    "network is unreachable",
    "urlopen error",
];

/// Whether `line` shows the script downloading: [`NETWORK`], or `curl` or
/// `wget` as a word outside a `cargo:` directive (`rustc-link-lib=curl`).
fn downloads(line: &str) -> bool {
    let lower = line.to_lowercase();
    if NETWORK.iter().any(|n| lower.contains(n)) {
        return true;
    }
    if lower.starts_with("cargo:") {
        return false;
    }
    let name_char = |c: char| c.is_ascii_alphanumeric() || "-_".contains(c);
    ["curl", "wget"].iter().any(|t| {
        lower.match_indices(t).any(|(i, _)| {
            !lower[..i].chars().next_back().is_some_and(name_char)
                && !lower[i + t.len()..].chars().next().is_some_and(name_char)
        })
    })
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
    for r in RECOGNIZERS {
        let ran = r.fingerprint.iter().any(|e| match e {
            Evidence::Var(p) => declared.iter().any(|v| var_matches(p, v)),
            Evidence::Line(p) => lines.clone().any(|l| glob(p, l.trim()).is_some()),
        });
        if !ran {
            continue;
        }
        let mut fired = false;
        for line in lines.clone().map(str::trim) {
            let Some((hint, cap)) = r
                .errors
                .iter()
                .find_map(|(p, h)| glob(p, line).map(|c| (h, c)))
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
            let matched: BTreeSet<&&str> = mine.iter().filter_map(first).collect();
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
                "({n} unset variable{s} of the `{}` crate omitted, matching {patterns}; \
                 {they} normally left unset)",
                r.crate_name
            ));
            covered.extend(mine);
        }
    }
    for line in lines.clone().map(str::trim) {
        if recognized.contains(line) {
            continue;
        }
        if let Some((tool, attr)) = named_tool(line) {
            push(
                &mut out,
                format!(
                    "`{tool}` is not in the sandbox; add it with `{opt}.nativeInputs = p: [ p.{attr} ];`"
                ),
                line,
            );
        }
    }
    if let Some(line) = lines.clone().map(str::trim).find(|l| downloads(l)) {
        push(
            &mut out,
            format!(
                "the build script seems to download; the sandbox has no network. If the crate \
                 can use a local copy, pass it in, usually through a variable it reads \
                 (`{opt}.env.<NAME>`, a `fetchurl` path)"
            ),
            line,
        );
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
