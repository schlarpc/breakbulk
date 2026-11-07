//! Canonical JSON.
//!
//! Compact (no insignificant whitespace), object keys sorted by their UTF-8
//! bytes, strings escaped as `serde_json` escapes them (`"`, `\` and control
//! characters; everything else verbatim UTF-8), integers only. The same value
//! always gives the same bytes, whatever order fields are declared or maps
//! are filled in, and whatever `serde_json` features other crates enable.
//!
//! Key order differs from RFC 8785 (which sorts by UTF-16 code units) only
//! for keys mixing characters above U+FFFF with characters in
//! U+E000..U+FFFF; plan keys are ASCII in practice.

use std::fmt;

use serde::Serialize;
use serde_json::Value;

#[derive(Debug)]
pub enum CanonicalError {
    Serialize(serde_json::Error),
    /// Floating-point numbers have no canonical form here.
    Float(String),
}

impl fmt::Display for CanonicalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CanonicalError::Serialize(e) => write!(f, "cannot serialize: {e}"),
            CanonicalError::Float(n) => write!(f, "non-integer number {n} in canonical JSON"),
        }
    }
}

impl std::error::Error for CanonicalError {}

/// Serialize `value` as canonical JSON.
pub fn to_canonical_json<T: Serialize + ?Sized>(value: &T) -> Result<String, CanonicalError> {
    let v = serde_json::to_value(value).map_err(CanonicalError::Serialize)?;
    let mut out = String::new();
    write_value(&v, &mut out)?;
    Ok(out)
}

fn write_value(v: &Value, out: &mut String) -> Result<(), CanonicalError> {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if !(n.is_i64() || n.is_u64()) {
                return Err(CanonicalError::Float(n.to_string()));
            }
            out.push_str(&n.to_string());
        }
        Value::String(s) => write_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_value(item, out)?;
            }
            out.push(']');
        }
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            entries.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
            out.push('{');
            for (i, (k, v)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_string(k, out);
                out.push(':');
                write_value(v, out)?;
            }
            out.push('}');
        }
    }
    Ok(())
}

fn write_string(s: &str, out: &mut String) {
    out.push_str(&serde_json::to_string(s).expect("strings always serialize"));
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::*;

    #[test]
    fn sorted_compact() {
        let v = serde_json::json!({"b": [1, {"z": null, "a": true}], "a": "x\"\n\u{1}é", "": -3});
        assert_eq!(
            to_canonical_json(&v).unwrap(),
            r#"{"":-3,"a":"x\"\n\u0001é","b":[1,{"a":true,"z":null}]}"#
        );
    }

    #[test]
    fn map_insertion_order_does_not_matter() {
        let mut a = HashMap::new();
        let mut b = HashMap::new();
        for i in 0..50 {
            a.insert(format!("k{i}"), i);
        }
        for i in (0..50).rev() {
            b.insert(format!("k{i}"), i);
        }
        assert_eq!(
            to_canonical_json(&a).unwrap(),
            to_canonical_json(&b).unwrap()
        );
    }

    #[test]
    fn floats_are_refused() {
        assert!(to_canonical_json(&1.5f64).is_err());
        assert_eq!(
            to_canonical_json(&u64::MAX).unwrap(),
            "18446744073709551615"
        );
    }
}
