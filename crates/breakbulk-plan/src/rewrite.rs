//! Path rewriting ("Path rewriting" in `docs/implementation.md`).
//!
//! Every recorded argument and env value is split into literal text and
//! references:
//!
//! | Recorded path | Becomes |
//! | --- | --- |
//! | a compile unit's output file (both build-directory layouts) | `{"out": unit, "output": …, "file": …}` |
//! | a run's `OUT_DIR`, or a path below it | `{"out": run, "output": "out"}` and the rest |
//! | `<skeleton>/<rel>` | `{"src": <path package>, "rel": <rel>}` |
//! | `<crate dir>/<rel>` of a non-path package | `{"crateSrc": <package id>, "rel": <rel>}` |
//!
//! Outputs are known from the shim's compile records, so no layout is
//! parsed: an output path is looked up as it is. Any other path inside the
//! planner's scratch directory is an error naming the value.

use std::collections::BTreeMap;

use breakbulk_format::{CrateSrcRef, OutRef, Piece, Platform, Reference, SrcRef, Text};

use crate::Error;
use crate::records::Metadata;

/// What a recorded absolute path can stand for.
#[derive(Clone, Debug, Default)]
pub struct Rewriter {
    /// The planner's scratch directory: target and build directory.
    pub scratch: String,
    /// The skeleton root: path packages live below it.
    pub skeleton: String,
    /// Path packages: directory → package id. Longest prefix wins.
    pub path_packages: Vec<(String, String)>,
    /// Other packages: crate directory (as Cargo names it, and resolved
    /// through symlinks) → package id.
    pub crate_dirs: Vec<(String, String)>,
    /// Compile outputs by path.
    pub outputs: BTreeMap<String, OutRef>,
    /// Run `OUT_DIR`s → run unit id.
    pub run_dirs: BTreeMap<String, String>,
    /// Bin outputs by (platform, target name), for the uplifted copies
    /// (`<profile dir>/<name>`) that `CARGO_BIN_EXE_<name>` names.
    pub uplifted_bins: BTreeMap<(Platform, String), OutRef>,
    /// The target triple: the first component of target units' paths.
    pub target_triple: String,
}

/// Characters that can continue a path name.
fn is_path_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c >= 0x80 || matches!(c, b'.' | b'-' | b'_' | b'+' | b'~' | b'/')
}

/// Where a path token ends: at a delimiter that cannot be part of the paths
/// breakbulk sees.
fn token_end(s: &str, from: usize) -> usize {
    s[from..]
        .find([':', ' ', '\t', '\n', ',', ';', '"', '\'', '='])
        .map_or(s.len(), |i| from + i)
}

fn under<'a>(path: &'a str, dir: &str) -> Option<&'a str> {
    let dir = dir.trim_end_matches('/');
    let rest = path.strip_prefix(dir)?;
    if rest.is_empty() {
        Some("")
    } else {
        rest.strip_prefix('/')
    }
}

impl Rewriter {
    pub fn new(scratch: &str, skeleton: &str, metadata: &Metadata) -> Rewriter {
        let mut r = Rewriter {
            scratch: scratch.trim_end_matches('/').to_owned(),
            skeleton: skeleton.trim_end_matches('/').to_owned(),
            ..Default::default()
        };
        for p in &metadata.packages {
            let dir = p.dir().to_owned();
            if p.is_path() {
                r.path_packages.push((dir, p.id.clone()));
            } else {
                if let Ok(c) = std::fs::canonicalize(&dir) {
                    let c = c.to_string_lossy().into_owned();
                    if c != dir {
                        r.crate_dirs.push((c, p.id.clone()));
                    }
                }
                r.crate_dirs.push((dir, p.id.clone()));
            }
        }
        // Longest first, so nested packages win.
        r.path_packages
            .sort_by_key(|(d, _)| std::cmp::Reverse(d.len()));
        r.crate_dirs
            .sort_by_key(|(d, _)| std::cmp::Reverse(d.len()));
        r
    }

    /// The prefixes a path to rewrite starts with.
    fn anchors(&self) -> impl Iterator<Item = &str> {
        [self.scratch.as_str(), self.skeleton.as_str()]
            .into_iter()
            .chain(self.crate_dirs.iter().map(|(d, _)| d.as_str()))
            .filter(|a| !a.is_empty())
    }

    /// The first anchored path in `s` at or after `from`: (start, end).
    fn next_path(&self, s: &str, from: usize) -> Option<(usize, usize)> {
        let b = s.as_bytes();
        let mut best: Option<usize> = None;
        for a in self.anchors() {
            let mut at = from;
            while let Some(off) = s[at..].find(a) {
                let i = at + off;
                let end = i + a.len();
                let start_ok = i == 0 || !is_path_char(b[i - 1]);
                let end_ok = end == b.len() || b[end] == b'/' || !is_path_char(b[end]);
                if start_ok && end_ok {
                    best = Some(best.map_or(i, |x| x.min(i)));
                    break;
                }
                at = i + 1;
                while !s.is_char_boundary(at) {
                    at += 1;
                }
            }
        }
        best.map(|i| (i, token_end(s, i)))
    }

    /// The references one absolute path becomes.
    pub fn path(&self, p: &str) -> Result<Vec<Piece>, Error> {
        for (dir, run) in &self.run_dirs {
            if let Some(rest) = under(p, dir) {
                let mut v = vec![Piece::Ref(Reference::Out(OutRef {
                    out: run.clone(),
                    output: "out".into(),
                    file: None,
                }))];
                if !rest.is_empty() {
                    v.push(Piece::Literal(format!("/{rest}")));
                }
                return Ok(v);
            }
        }
        if let Some(o) = self.outputs.get(p) {
            return Ok(vec![Piece::Ref(Reference::Out(o.clone()))]);
        }
        if let Some(rel) = under(p, &self.scratch) {
            let platform = match rel.split('/').next() {
                Some(t) if t == self.target_triple => Platform::Target,
                _ => Platform::Host,
            };
            let name = rel.rsplit('/').next().unwrap_or(rel);
            if let Some(o) = self.uplifted_bins.get(&(platform, name.to_owned())) {
                return Ok(vec![Piece::Ref(Reference::Out(o.clone()))]);
            }
            return Err(Error(format!(
                "`{p}` is in the planner's build directory but is no unit's output \
                 and no build script's OUT_DIR"
            )));
        }
        if under(p, &self.skeleton).is_some() {
            let Some((_, id)) = self
                .path_packages
                .iter()
                .find(|(d, _)| under(p, d).is_some())
            else {
                return Err(Error(format!(
                    "`{p}` is in the skeleton but in no package's directory"
                )));
            };
            let rel = under(p, &self.skeleton).expect("checked above").to_owned();
            return Ok(vec![Piece::Ref(Reference::Src(SrcRef {
                src: id.clone(),
                rel,
            }))]);
        }
        for (dir, id) in &self.crate_dirs {
            if let Some(rest) = under(p, dir) {
                return Ok(vec![Piece::Ref(Reference::CrateSrc(CrateSrcRef {
                    crate_src: id.clone(),
                    rel: rest.to_owned(),
                }))]);
            }
        }
        Err(Error(format!("cannot rewrite the path `{p}`")))
    }

    /// Split a recorded value into literals and references.
    pub fn text(&self, s: &str) -> Result<Text, Error> {
        let mut pieces = Vec::new();
        let mut at = 0;
        while let Some((i, end)) = self.next_path(s, at) {
            if i > at {
                pieces.push(Piece::Literal(s[at..i].to_owned()));
            }
            pieces.extend(self.path(&s[i..end])?);
            at = end;
        }
        if at < s.len() {
            pieces.push(Piece::Literal(s[at..].to_owned()));
        }
        Ok(breakbulk_format::normalize_text(Text::Concat(pieces)))
    }

    /// A value that must be exactly one reference (a working directory).
    pub fn reference(&self, s: &str) -> Result<Reference, Error> {
        match self.text(s)? {
            Text::Concat(p) => match p.as_slice() {
                [Piece::Ref(r)] => Ok(r.clone()),
                _ => Err(Error(format!("`{s}` is not one source or output path"))),
            },
            Text::Literal(_) => Err(Error(format!("`{s}` is not one source or output path"))),
        }
    }

    /// Whether `p` is inside the scratch directory.
    pub fn in_scratch(&self, p: &str) -> bool {
        under(p, &self.scratch).is_some()
    }
}
