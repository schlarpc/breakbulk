//! Normal form of a plan, applied before canonical serialization.
//!
//! - In a concatenation, adjacent literals are merged and empty literals
//!   dropped; a concatenation of literals only becomes a plain literal. A
//!   concatenation with a reference stays an array.
//! - Arrays that are sets are sorted and deduplicated: `roots`, a run's
//!   `targets` (and each target's kinds), a crate's `types`. Arrays whose
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
    let env = |env: &mut std::collections::BTreeMap<String, Text>| {
        for v in env.values_mut() {
            *v = normalize_text(std::mem::replace(v, Text::Literal(String::new())));
        }
    };
    match unit {
        Unit::Compile(c) => {
            c.program = std::mem::take(&mut c.program)
                .into_iter()
                .map(normalize_text)
                .collect();
            c.args = std::mem::take(&mut c.args)
                .into_iter()
                .map(normalize_arg)
                .collect();
            env(&mut c.env);
            sort_dedup(&mut c.krate.types);
        }
        Unit::Run(r) => {
            env(&mut r.env);
            for t in &mut r.targets {
                sort_dedup(&mut t.kind);
            }
            sort_dedup(&mut r.targets);
        }
    }
}

impl Plan {
    /// Bring the plan into normal form (see the module docs).
    pub fn normalize(&mut self) {
        for u in self.units.values_mut() {
            normalize_unit(u);
        }
        for d in self.doctests.values_mut() {
            d.program = std::mem::take(&mut d.program)
                .into_iter()
                .map(normalize_text)
                .collect();
            d.args = std::mem::take(&mut d.args)
                .into_iter()
                .map(|a| match normalize_arg(a) {
                    Arg::SearchPaths(mut s) => {
                        sort_dedup(&mut s.search_paths_of);
                        Arg::SearchPaths(s)
                    }
                    a => a,
                })
                .collect();
            for v in d.env.values_mut() {
                *v = normalize_text(std::mem::replace(v, Text::Literal(String::new())));
            }
            sort_dedup(&mut d.krate.types);
        }
        sort_dedup(&mut self.roots);
    }
}
