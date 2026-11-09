//! Sentinels: finding them in traced argv and env, checking their shapes
//! against the sentinel table, and turning them into splice points
//! (`docs/src/reference/sentinels.md`).

use breakbulk_format::{LinkArgKind, SpliceKind, contains_sentinel};

/// One sentinel argument pair, as Cargo placed it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ArgSentinel {
    /// `--cfg __bb_R_cfg`
    Cfg(String),
    /// `--check-cfg cfg(__bb_R_ccfg)`
    CheckCfg(String),
    /// `-l __bb_R_lib`
    Lib(String),
    /// `-L native=<dir>/__bb_R_search`: the directory is R's `OUT_DIR`.
    SearchIn(String, String),
    /// `-L native=/__bb_R_search_ext`
    SearchOther(String),
    /// `-C link-arg=__bb_R_arg…`
    LinkArg(String, LinkArgKind),
}

impl ArgSentinel {
    pub fn tag(&self) -> &str {
        match self {
            ArgSentinel::Cfg(t)
            | ArgSentinel::CheckCfg(t)
            | ArgSentinel::Lib(t)
            | ArgSentinel::SearchIn(t, _)
            | ArgSentinel::SearchOther(t)
            | ArgSentinel::LinkArg(t, _) => t,
        }
    }
}

/// `__bb_<tag>_<rest>` → (tag, rest). Tags are Cargo's lowercase hex hashes.
fn split_tag(s: &str) -> Option<(&str, &str)> {
    let s = s.strip_prefix("__bb_")?;
    let (tag, rest) = s.split_once('_')?;
    (!tag.is_empty()
        && tag
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()))
    .then_some((tag, rest))
}

/// Parse the argument pair (`flag`, `value`) as a sentinel. `None` if the
/// pair holds no sentinel token; `Some(Err)` if it holds one in a shape the
/// sentinel table does not allow.
pub fn parse_pair(flag: &str, value: &str) -> Option<Result<ArgSentinel, String>> {
    if !contains_sentinel(value) && !contains_sentinel(flag) {
        return None;
    }
    let bad = || Err(format!("`{flag} {value}`"));
    Some(match flag {
        "--cfg" => match split_tag(value) {
            Some((t, "cfg")) => Ok(ArgSentinel::Cfg(t.into())),
            _ => bad(),
        },
        "--check-cfg" => match value
            .strip_prefix("cfg(")
            .and_then(|v| v.strip_suffix(')'))
            .and_then(split_tag)
        {
            Some((t, "ccfg")) => Ok(ArgSentinel::CheckCfg(t.into())),
            _ => bad(),
        },
        "-l" => match split_tag(value) {
            Some((t, "lib")) => Ok(ArgSentinel::Lib(t.into())),
            _ => bad(),
        },
        "-L" => {
            let Some(p) = value.strip_prefix("native=") else {
                return Some(bad());
            };
            if let Some((t, "search_ext")) = p.strip_prefix('/').and_then(split_tag) {
                return Some(Ok(ArgSentinel::SearchOther(t.into())));
            }
            match p.rsplit_once('/') {
                Some((dir, last)) if !dir.is_empty() => match split_tag(last) {
                    Some((t, "search")) => Ok(ArgSentinel::SearchIn(t.into(), dir.into())),
                    _ => bad(),
                },
                _ => bad(),
            }
        }
        "-C" => {
            let Some((t, rest)) = value.strip_prefix("link-arg=").and_then(split_tag) else {
                return Some(bad());
            };
            let kind = match rest {
                "arg" => LinkArgKind::new(SpliceKind::RustcLinkArg),
                "arg_bins" => LinkArgKind::new(SpliceKind::RustcLinkArgBins),
                "arg_tests" => LinkArgKind::new(SpliceKind::RustcLinkArgTests),
                "arg_examples" => LinkArgKind::new(SpliceKind::RustcLinkArgExamples),
                "arg_benches" => LinkArgKind::new(SpliceKind::RustcLinkArgBenches),
                "arg_cdylib" => LinkArgKind::new(SpliceKind::RustcLinkArgCdylib),
                r => match r.strip_prefix("arg_bin_") {
                    Some(name) if !name.is_empty() => LinkArgKind::bin(name),
                    _ => return Some(bad()),
                },
            };
            Ok(ArgSentinel::LinkArg(t.into(), kind))
        }
        _ => bad(),
    })
}

/// `__BB_<TAG>_ENV` → tag (lowercased), when `value` is `__bb_<tag>_env`.
pub fn env_sentinel(name: &str, value: &str) -> Option<Result<String, String>> {
    let rest = name.strip_prefix("__BB_")?;
    let tag = rest.strip_suffix("_ENV")?.to_ascii_lowercase();
    Some(if value == format!("__bb_{tag}_env") {
        Ok(tag)
    } else {
        Err(format!("`{name}={value}`"))
    })
}

/// `DEP_<LINKS>___BB=<tag>` on a run → (links, tag).
pub fn dep_sentinel<'a>(name: &'a str, value: &'a str) -> Option<(&'a str, &'a str)> {
    let links = name.strip_prefix("DEP_")?.strip_suffix("___BB")?;
    Some((links, value))
}

/// A dynamic-library path entry `<OUT_DIR>/__bb_R_search` → (tag, dir).
pub fn dylib_sentinel(entry: &str) -> Option<(String, String)> {
    let (dir, last) = entry.rsplit_once('/')?;
    match split_tag(last) {
        Some((t, "search")) => Some((t.to_owned(), dir.to_owned())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes() {
        assert_eq!(
            parse_pair("--cfg", "__bb_0a1b_cfg"),
            Some(Ok(ArgSentinel::Cfg("0a1b".into())))
        );
        assert_eq!(
            parse_pair("--check-cfg", "cfg(__bb_0a1b_ccfg)"),
            Some(Ok(ArgSentinel::CheckCfg("0a1b".into())))
        );
        assert_eq!(
            parse_pair("-l", "__bb_0a1b_lib"),
            Some(Ok(ArgSentinel::Lib("0a1b".into())))
        );
        assert_eq!(
            parse_pair("-L", "native=/t/build/x-0a1b/out/__bb_0a1b_search"),
            Some(Ok(ArgSentinel::SearchIn(
                "0a1b".into(),
                "/t/build/x-0a1b/out".into()
            )))
        );
        assert_eq!(
            parse_pair("-L", "native=/__bb_0a1b_search_ext"),
            Some(Ok(ArgSentinel::SearchOther("0a1b".into())))
        );
        assert_eq!(
            parse_pair("-C", "link-arg=__bb_0a1b_arg_bin_my-app_2"),
            Some(Ok(ArgSentinel::LinkArg(
                "0a1b".into(),
                LinkArgKind::bin("my-app_2")
            )))
        );
        assert_eq!(
            parse_pair("-C", "link-arg=__bb_0a1b_arg_tests"),
            Some(Ok(ArgSentinel::LinkArg(
                "0a1b".into(),
                LinkArgKind::new(SpliceKind::RustcLinkArgTests)
            )))
        );
        assert_eq!(parse_pair("--cfg", "feature=\"x\""), None);
        assert!(matches!(parse_pair("--cfg", "__bb_0a1b_lib"), Some(Err(_))));
        assert!(matches!(
            parse_pair("-l", "static=__bb_0a1b_lib"),
            Some(Err(_))
        ));
        assert!(matches!(
            parse_pair("-L", "/__bb_0a1b_search_ext"),
            Some(Err(_))
        ));
        assert!(matches!(
            parse_pair("-C", "link-arg=__bb_0a1b_arg_bin_"),
            Some(Err(_))
        ));
        assert!(matches!(parse_pair("-Z", "__bb_0a1b_cfg"), Some(Err(_))));
    }

    #[test]
    fn env_shapes() {
        assert_eq!(
            env_sentinel("__BB_0A1B_ENV", "__bb_0a1b_env"),
            Some(Ok("0a1b".into()))
        );
        assert!(matches!(env_sentinel("__BB_0A1B_ENV", "x"), Some(Err(_))));
        assert_eq!(env_sentinel("PATH", "x"), None);
        assert_eq!(
            dep_sentinel("DEP_FOO_BAR___BB", "0a1b"),
            Some(("FOO_BAR", "0a1b"))
        );
        assert_eq!(
            dylib_sentinel("/t/x-0a1b/out/__bb_0a1b_search"),
            Some(("0a1b".into(), "/t/x-0a1b/out".into()))
        );
        assert_eq!(dylib_sentinel("/t/debug/deps"), None);
    }
}
