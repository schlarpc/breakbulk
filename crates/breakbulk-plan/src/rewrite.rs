//! Path rewriting ("Path rewriting" in
//! `docs/src/explanation/internals/planner.md`).
//!
//! Every recorded argument and env value is split into literal text and
//! references:
//!
//! | Recorded path | Becomes |
//! | --- | --- |
//! | a compile unit's output file (both build-directory layouts) | `{"out": unit, "output": …, "file": …}` |
//! | a run's `OUT_DIR`, or a path below it | `{"out": run, "output": "out"}` and the rest |
//! | `<skeleton>/<rel>` in a path package's unit | `{"src": <that package>, "rel": <rel>}` |
//! | `<skeleton>/<rel>` in another package's unit | `{"empty": <rel>}` |
//! | `<crate dir>/<rel>` of a non-path package | `{"crateSrc": <package id>, "rel": <rel>}` |
//!
//! Outputs are known from the shim's compile records, so no layout is
//! parsed: an output path is looked up as it is. Any other path inside the
//! planner's scratch directory is an error naming the value.

use std::collections::{BTreeMap, BTreeSet};

use breakbulk_format::{CrateSrcRef, EmptyRef, OutRef, Piece, Platform, Reference, SrcRef, Text};

use crate::Error;
use crate::records::Metadata;

/// What a recorded absolute path can stand for.
#[derive(Clone, Debug, Default)]
pub struct Rewriter {
    /// The planner's scratch directory: target and build directory.
    pub scratch: String,
    /// The skeleton root: path packages live below it.
    pub skeleton: String,
    /// The packages with a source view: the path packages in the
    /// skeleton. Registry and git crates have none, nor, under
    /// -Zbuild-std, the standard library's path packages.
    pub viewed: BTreeSet<String>,
    /// Other packages: crate directory (as Cargo names it, and resolved
    /// through symlinks) → package id.
    pub crate_dirs: Vec<(String, String)>,
    /// Compile outputs by path.
    pub outputs: BTreeMap<String, OutRef>,
    /// Run `OUT_DIR`s → run unit id and the `OUT_DIR` relative to Cargo's
    /// target directory, which is where it sits inside the run's `out`
    /// (#23).
    pub run_dirs: BTreeMap<String, (String, String)>,
    /// Bin outputs by (platform, file name), with their package ids, for
    /// the uplifted copies (`<profile dir>/<name><suffix>`) that
    /// `CARGO_BIN_EXE_<name>` names, whose file name the bin units store
    /// their files under. Two packages can have a bin of the same
    /// name (Cargo warns about the collision): then the owner's own bin is
    /// meant, because Cargo sets `CARGO_BIN_EXE_*` only for the bins of the
    /// test's own package (`artifact.rs`, `get_env`).
    pub uplifted_bins: BTreeMap<(Platform, String), Vec<(String, OutRef)>>,
    /// The target triple: the first component of target units' paths.
    pub target_triple: String,
    /// `-Zbuild-std`: crates of the merged crates.io directory that are
    /// the toolchain's own (`library/vendor`): directory → its store path,
    /// kept as a literal like every toolchain path.
    pub literal_dirs: Vec<(String, String)>,
}

/// Characters that can continue a path name.
fn is_path_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c >= 0x80 || matches!(c, b'.' | b'-' | b'_' | b'+' | b'~' | b'/')
}

/// Where a path token ends: at a delimiter that cannot be part of the paths
/// breakbulk sees, or a control character (Cargo separates the flags in
/// `CARGO_ENCODED_RUSTFLAGS` with `\x1f`).
fn token_end(s: &str, from: usize) -> usize {
    s[from..]
        .find(|c: char| c.is_ascii_control() || [':', ' ', ',', ';', '"', '\'', '='].contains(&c))
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
                if under(&dir, &r.skeleton).is_some() {
                    r.viewed.insert(p.id.clone());
                }
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
        r.crate_dirs
            .sort_by_key(|(d, _)| std::cmp::Reverse(d.len()));
        r
    }

    /// `-Zbuild-std`: the merged crates.io directory `dir`
    /// ([`crate::build_std`]) and the toolchain's `library`. A crate
    /// linked from the project's vendor directory is that crate's source; one
    /// linked from the toolchain's `library/vendor` is a toolchain path and
    /// stays a literal, like the standard library's own packages.
    pub fn add_std_vendor(&mut self, dir: &str, library: &str) -> Result<(), Error> {
        let library = std::fs::canonicalize(library)
            .map_err(|e| Error(format!("resolving {library}: {e}")))?
            .to_string_lossy()
            .into_owned();
        let rd = std::fs::read_dir(dir).map_err(|e| Error(format!("reading {dir}: {e}")))?;
        let mut toolchain = Vec::new();
        for e in rd.flatten() {
            let from = format!(
                "{}/{}",
                dir.trim_end_matches('/'),
                e.file_name().to_string_lossy()
            );
            let c = std::fs::canonicalize(&from)
                .map_err(|e| Error(format!("resolving {from}: {e}")))?
                .to_string_lossy()
                .into_owned();
            if under(&c, &library).is_some() {
                toolchain.push(from.clone());
                self.literal_dirs.push((from, c));
            }
        }
        // The standard library's registry packages from `cargo metadata`
        // are no fetched crates: neither their directory in the merged one
        // nor the toolchain path it resolves to is a crate source.
        self.crate_dirs
            .retain(|(d, _)| under(d, &library).is_none() && !toolchain.contains(d));
        Ok(())
    }

    /// The prefixes a path to rewrite starts with.
    fn anchors(&self) -> impl Iterator<Item = &str> {
        [self.scratch.as_str(), self.skeleton.as_str()]
            .into_iter()
            .chain(self.literal_dirs.iter().map(|(d, _)| d.as_str()))
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
    pub fn path(&self, p: &str, owner: Option<&str>) -> Result<Vec<Piece>, Error> {
        for (dir, (run, rel)) in &self.run_dirs {
            if let Some(rest) = under(p, dir) {
                let mut v = vec![Piece::Ref(Reference::Out(OutRef {
                    out: run.clone(),
                    output: "out".into(),
                    file: None,
                }))];
                let inside = [rel.as_str(), rest]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join("/");
                if !inside.is_empty() {
                    v.push(Piece::Literal(format!("/{inside}")));
                }
                return Ok(v);
            }
        }
        if let Some(o) = self.outputs.get(p) {
            return Ok(vec![Piece::Ref(Reference::Out(o.clone()))]);
        }
        for (dir, lit) in &self.literal_dirs {
            if let Some(rest) = under(p, dir) {
                let mut s = lit.clone();
                if !rest.is_empty() {
                    s.push('/');
                    s.push_str(rest);
                }
                return Ok(vec![Piece::Literal(s)]);
            }
        }
        // Before the scratch directory: with -Zbuild-std, crates of the
        // merged crates.io directory there.
        for (dir, id) in &self.crate_dirs {
            if let Some(rest) = under(p, dir) {
                return Ok(vec![Piece::Ref(Reference::CrateSrc(CrateSrcRef {
                    crate_src: id.clone(),
                    rel: rest.to_owned(),
                }))]);
            }
        }
        if let Some(rel) = under(p, &self.scratch) {
            let platform = match rel.split('/').next() {
                Some(t) if t == self.target_triple => Platform::Target,
                _ => Platform::Host,
            };
            let name = rel.rsplit('/').next().unwrap_or(rel);
            if let Some(bins) = self.uplifted_bins.get(&(platform, name.to_owned())) {
                let own: Vec<&OutRef> = bins
                    .iter()
                    .filter(|(pkg, _)| Some(pkg.as_str()) == owner)
                    .map(|(_, o)| o)
                    .collect();
                let one = match (bins.as_slice(), own.as_slice()) {
                    ([(_, o)], _) => Some(o),
                    (_, [o]) => Some(*o),
                    _ => None,
                };
                if let Some(o) = one {
                    return Ok(vec![Piece::Ref(Reference::Out(o.clone()))]);
                }
            }
            return Err(Error(format!(
                "`{p}` is in the planner's build directory but is no unit's output \
                 and no build script's OUT_DIR"
            )));
        }
        if let Some(rel) = under(p, &self.skeleton) {
            // In the owning unit's own view (rooted at the repository root,
            // like every view), not in the view of the package whose
            // directory holds the path: that would tie the unit to all of
            // that package's files (all of the root package's, for the
            // workspace root, Cargo's working directory for members), and
            // the root package's view leaves out its members' directories.
            let Some(owner) = owner else {
                return Err(Error(format!(
                    "`{p}` is in the repository, but the value belongs to no package"
                )));
            };
            let rel = rel.to_owned();
            let r = if self.viewed.contains(owner) {
                Reference::Src(SrcRef {
                    src: owner.to_owned(),
                    rel,
                })
            } else {
                Reference::Empty(EmptyRef { rel })
            };
            return Ok(vec![Piece::Ref(r)]);
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
    pub fn text(&self, s: &str, owner: Option<&str>) -> Result<Text, Error> {
        let mut pieces = Vec::new();
        let mut at = 0;
        while let Some((i, end)) = self.next_path(s, at) {
            if i > at {
                pieces.push(Piece::Literal(s[at..i].to_owned()));
            }
            // A trailing `/` stays text: a reference to a directory resolves
            // without one (`relative = true` with an empty value names the
            // config's directory with a trailing `/`).
            let p = &s[i..end];
            let p = p.strip_suffix('/').filter(|p| !p.is_empty()).unwrap_or(p);
            pieces.extend(self.path(p, owner)?);
            at = i + p.len();
        }
        if at < s.len() {
            pieces.push(Piece::Literal(s[at..].to_owned()));
        }
        Ok(breakbulk_format::normalize_text(Text::Concat(pieces)))
    }

    /// A value that must be exactly one reference (a working directory).
    pub fn reference(&self, s: &str, owner: Option<&str>) -> Result<Reference, Error> {
        match self.text(s, owner)? {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoded_rustflags_separators_end_paths() {
        let app = "path+file:///build/skeleton/app#0.1.0";
        let r = Rewriter {
            scratch: "/build/scratch/target".into(),
            skeleton: "/build/skeleton".into(),
            viewed: [app.to_owned()].into(),
            ..Default::default()
        };
        let src = |rel: &str| {
            Piece::Ref(Reference::Src(SrcRef {
                src: app.into(),
                rel: rel.into(),
            }))
        };
        let t = r
            .text(
                "-L\x1f/build/skeleton/app/a\x1f-L\x1f/build/skeleton/app/b",
                Some(app),
            )
            .unwrap();
        assert_eq!(
            t,
            Text::Concat(vec![
                Piece::Literal("-L\x1f".into()),
                src("app/a"),
                Piece::Literal("\x1f-L\x1f".into()),
                src("app/b"),
            ])
        );
    }

    #[test]
    fn repository_paths_resolve_in_the_owners_view() {
        let app = "path+file:///build/skeleton#app@0.1.0";
        let lib1 = "path+file:///build/skeleton/crates/lib1#0.1.0";
        let itoa = "registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.11";
        let r = Rewriter {
            scratch: "/build/scratch/target".into(),
            skeleton: "/build/skeleton".into(),
            viewed: [app.to_owned(), lib1.to_owned()].into(),
            ..Default::default()
        };
        let src = |id: &str, rel: &str| {
            vec![Piece::Ref(Reference::Src(SrcRef {
                src: id.into(),
                rel: rel.into(),
            }))]
        };
        // The workspace root and a path in another package's directory:
        // each unit's own view, also for a member nested in the root
        // package's directory.
        for p in [
            "/build/skeleton",
            "/build/skeleton/assets",
            "/build/skeleton/src",
        ] {
            let rel = under(p, "/build/skeleton").unwrap();
            assert_eq!(r.path(p, Some(lib1)).unwrap(), src(lib1, rel));
            assert_eq!(r.path(p, Some(app)).unwrap(), src(app, rel));
        }
        assert_eq!(
            r.path("/build/skeleton/crates/lib1/data", Some(app))
                .unwrap(),
            src(app, "crates/lib1/data")
        );
        // A registry crate's unit has no view: the empty directory.
        assert_eq!(
            r.path("/build/skeleton/assets", Some(itoa)).unwrap(),
            vec![Piece::Ref(Reference::Empty(EmptyRef {
                rel: "assets".into()
            }))]
        );
        assert!(r.path("/build/skeleton/assets", None).is_err());
        // `relative = true` with an empty value: the trailing `/` stays.
        let mut root = src(lib1, "");
        root.push(Piece::Literal("/".into()));
        assert_eq!(
            r.text("/build/skeleton/", Some(lib1)).unwrap(),
            Text::Concat(root)
        );
    }

    #[test]
    fn uplifted_bin_of_the_owners_package() {
        let (a, b) = ("path+file:///s/a#0.1.0", "path+file:///s/b#0.1.0");
        let out = |u: &str| OutRef {
            out: u.into(),
            output: "bin".into(),
            file: Some("tool".into()),
        };
        let t = "x86_64-unknown-linux-gnu";
        let mut r = Rewriter {
            scratch: "/build/scratch/target".into(),
            skeleton: "/build/skeleton".into(),
            target_triple: t.into(),
            ..Default::default()
        };
        let key = (Platform::Target, "tool".to_owned());
        r.uplifted_bins.insert(
            key.clone(),
            vec![(a.into(), out("c-a")), (b.into(), out("c-b"))],
        );
        let p = format!("/build/scratch/target/{t}/release/tool");
        // Two packages have a bin `tool`: each package's tests get their own.
        for (owner, unit) in [(a, "c-a"), (b, "c-b")] {
            assert_eq!(
                r.path(&p, Some(owner)).unwrap(),
                vec![Piece::Ref(Reference::Out(out(unit)))]
            );
        }
        // No owner among them: ambiguous.
        assert!(r.path(&p, Some("other")).is_err());
        // One bin of that name: it, whoever refers to it.
        r.uplifted_bins.insert(key, vec![(a.into(), out("c-a"))]);
        assert_eq!(
            r.path(&p, Some(b)).unwrap(),
            vec![Piece::Ref(Reference::Out(out("c-a")))]
        );
    }
}
