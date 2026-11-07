//! Rendering rustc's JSON messages for the build log.
//!
//! Cargo runs rustc with `--error-format=json --json=…artifacts,…`, so
//! rustc's stderr is one JSON object per line. `breakbulk-unit` prints the
//! `rendered` text of each diagnostic, as Cargo does, and drops artifact
//! notifications and unused-extern reports. Lines that are not rustc JSON (a linker's output, an ICE
//! backtrace, a wrapper's own messages) pass through unchanged.

use serde::Deserialize;

#[derive(Deserialize)]
struct Message {
    #[serde(rename = "$message_type")]
    message_type: Option<String>,
    rendered: Option<String>,
    future_incompat_report: Option<Vec<serde::de::IgnoredAny>>,
}

/// What to do with one line of rustc's stderr.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Line {
    /// Print this text (it has its own line ends, as rustc renders it).
    Print(String),
    /// Print nothing.
    Drop,
    /// A future-incompatibility report with this many entries; Cargo
    /// summarizes these instead of printing them.
    FutureIncompat(usize),
}

/// Classify one line of stderr (without its line end).
pub fn classify(line: &str) -> Line {
    let raw = || Line::Print(format!("{line}\n"));
    if !line.starts_with('{') {
        return raw();
    }
    let Ok(m) = serde_json::from_str::<Message>(line) else {
        return raw();
    };
    match m.message_type.as_deref() {
        // `unused_extern`: nightly Cargo asks for these
        // (`--json=unused-externs-silent`) for its own unused-dependency
        // lint, which is Cargo's to report, not a diagnostic.
        Some("artifact" | "unused_extern") => Line::Drop,
        Some("diagnostic") => match m.rendered {
            Some(r) if r.ends_with('\n') => Line::Print(r),
            Some(r) => Line::Print(format!("{r}\n")),
            None => Line::Drop,
        },
        Some("future_incompat") => {
            Line::FutureIncompat(m.future_incompat_report.map_or(0, |r| r.len()))
        }
        _ => raw(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artifacts_are_dropped() {
        assert_eq!(
            classify(
                r#"{"$message_type":"artifact","artifact":"/build/out/libx.rmeta","emit":"metadata"}"#
            ),
            Line::Drop
        );
        assert_eq!(
            classify(
                r#"{"$message_type":"unused_extern","lint_level":"force-warn","unused_extern_names":[]}"#
            ),
            Line::Drop
        );
    }

    #[test]
    fn diagnostics_print_rendered() {
        let line = r#"{"$message_type":"diagnostic","message":"unused variable: `x`","code":null,"level":"warning","spans":[],"children":[],"rendered":"warning: unused variable: `x`\n --> src/lib.rs:1:5\n\n"}"#;
        assert_eq!(
            classify(line),
            Line::Print("warning: unused variable: `x`\n --> src/lib.rs:1:5\n\n".into())
        );
        assert_eq!(
            classify(r#"{"$message_type":"diagnostic","rendered":"error: x"}"#),
            Line::Print("error: x\n".into())
        );
        assert_eq!(
            classify(r#"{"$message_type":"diagnostic","rendered":null}"#),
            Line::Drop
        );
    }

    #[test]
    fn other_lines_pass_through() {
        assert_eq!(
            classify("note: linker said hello"),
            Line::Print("note: linker said hello\n".into())
        );
        assert_eq!(classify("{not json"), Line::Print("{not json\n".into()));
        assert_eq!(
            classify(r#"{"$message_type":"section_timing","x":1}"#),
            Line::Print("{\"$message_type\":\"section_timing\",\"x\":1}\n".into())
        );
        assert_eq!(
            classify(r#"{"$message_type":"future_incompat","future_incompat_report":[{},{}]}"#),
            Line::FutureIncompat(2)
        );
    }
}
