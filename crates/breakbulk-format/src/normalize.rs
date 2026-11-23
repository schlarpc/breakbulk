//! Normal form of a plan, applied before canonical serialization.
//!
//! - In a concatenation, adjacent literals are merged and empty literals
//!   dropped; a concatenation of literals only becomes a plain literal. A
//!   concatenation with a reference stays an array.
//! - Arrays that are sets are sorted and deduplicated:
//!   a package's `targets` (and each target's kinds), a crate's `types`,
//!   a package's `dependencies`, a doctest's `searchPathsOf`. Sets typed as
//!   `BTreeSet` (`roots`, `features`, `metadataFrom`, an output's files)
//!   are kept sorted and deduplicated by their type. Arrays whose
//!   order matters (`args`, `program`, `envSplices`) keep their order.

use crate::plan::{Arg, Piece, Plan, Text, Unit};

fn normalize_pieces(pieces: Vec<Piece>) -> Text {
    let mut out: Vec<Piece> = Vec::with_capacity(pieces.len());
    for p in pieces {
        match p {
            Piece::Literal(s) if s.is_empty() => {}
            Piece::Literal(s) => match out.last_mut() {
                Some(Piece::Literal(prev)) => prev.push_str(&s),
                _ => out.push(Piece::Literal(s)),
            },
            r @ Piece::Ref(_) => out.push(r),
        }
    }
    match out.as_slice() {
        [] => Text::Literal(String::new()),
        [Piece::Literal(s)] => Text::Literal(s.clone()),
        _ => Text::Concat(out),
    }
}

pub fn normalize_text(t: Text) -> Text {
    match t {
        Text::Concat(p) => normalize_pieces(p),
        lit => lit,
    }
}

pub fn normalize_arg(a: Arg) -> Arg {
    match a {
        Arg::Concat(p) => normalize_pieces(p).into(),
        other => other,
    }
}

fn sort_dedup<T: Ord>(v: &mut Vec<T>) {
    v.sort();
    v.dedup();
}

pub fn normalize_unit(unit: &mut Unit) {
    unit.program = std::mem::take(&mut unit.program)
        .into_iter()
        .map(normalize_text)
        .collect();
    unit.args = std::mem::take(&mut unit.args)
        .into_iter()
        .map(|a| match normalize_arg(a) {
            Arg::SearchPaths(mut s) => {
                sort_dedup(&mut s.search_paths_of);
                sort_dedup(&mut s.literals);
                Arg::SearchPaths(s)
            }
            a => a,
        })
        .collect();
    for v in unit.env.values_mut() {
        *v = normalize_text(std::mem::replace(v, Text::Literal(String::new())));
    }
    if let Some(k) = &mut unit.krate {
        sort_dedup(&mut k.types);
    }
}

impl Plan {
    /// Bring the plan into normal form (see the module docs).
    pub fn normalize(&mut self) {
        for u in self.units.values_mut() {
            normalize_unit(u);
        }
        for p in self.packages.values_mut() {
            for t in &mut p.targets {
                sort_dedup(&mut t.kind);
            }
            sort_dedup(&mut p.targets);
            for d in &mut p.dependencies {
                sort_dedup(&mut d.kinds);
            }
            sort_dedup(&mut p.dependencies);
        }
    }
}
