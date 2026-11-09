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
//! The table is not user-extensible: recognizers run inside the unit
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
    // clang-sys's `llvm-config` warning first when it is missing.
    Recognizer {
        crate_name: "bindgen/clang-sys",
        fingerprint: &[
            Evidence::Var("BINDGEN_EXTRA_CLANG_ARGS*"),
            Evidence::Var("LIBCLANG_PATH"),
            Evidence::Line("*could not execute `llvm-config` one or more times*"),
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

/// The hints for a failed run: one per recognized failure, then the unset
/// `unset` variables (in the order declared), summarized for each
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
            let hint = hint.replace("{0}", &cap).replace("{opt}", opt);
            if seen.insert(hint.clone()) {
                out.push(format!(
                    "{hint}\n      (the build script printed: {})",
                    quote(line)
                ));
            }
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
            let families = r
                .covers
                .iter()
                .map(|p| format!("`{p}`"))
                .collect::<Vec<_>>()
                .join(", ");
            let n = mine.len();
            let s = if n == 1 { "" } else { "s" };
            out.push(format!(
                "({n} unset variable{s} of the `{}` crate omitted ({families}); they are normally left unset)",
                r.crate_name
            ));
            covered.extend(mine);
        }
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
