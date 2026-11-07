//! Rendering a plan unit into the `BREAKBULK_UNIT` value.

use std::collections::BTreeMap;

use breakbulk_unit::spec::{RenderedArg, RenderedCompile, RenderedRun, RenderedUnit};

use crate::normalize::normalize_unit;
use crate::plan::{Arg, Piece, Reference, Text, Unit, UnitId};
use crate::{CanonicalError, Splice, to_canonical_json};

/// How instantiation resolves what a unit names.
pub trait Resolve {
    type Error;
    /// The literal path a reference stands for.
    fn reference(&self, r: &Reference) -> Result<String, Self::Error>;
    /// The `flags` output directory of a run unit.
    fn flags(&self, run: &UnitId) -> Result<String, Self::Error>;
}

fn text<R: Resolve>(t: &Text, r: &R) -> Result<String, R::Error> {
    match t {
        Text::Literal(s) => Ok(s.clone()),
        Text::Concat(pieces) => {
            let mut out = String::new();
            for p in pieces {
                match p {
                    Piece::Literal(s) => out.push_str(s),
                    Piece::Ref(x) => out.push_str(&r.reference(x)?),
                }
            }
            Ok(out)
        }
    }
}

fn env<R: Resolve>(
    e: &BTreeMap<String, Text>,
    r: &R,
) -> Result<BTreeMap<String, String>, R::Error> {
    e.iter()
        .map(|(k, v)| Ok((k.clone(), text(v, r)?)))
        .collect()
}

fn splice<R: Resolve>(s: &Splice, r: &R) -> Result<breakbulk_unit::spec::Splice<String>, R::Error> {
    Ok(breakbulk_unit::spec::Splice {
        splice: r.flags(&s.splice)?,
        kind: s.kind,
        bin: s.bin.clone(),
    })
}

/// Render one unit: every reference becomes a path, every splice names its
/// run's `flags` directory. The unit is normalized first, so equal units
/// render equally.
pub fn render_unit<R: Resolve>(unit: &Unit, r: &R) -> Result<RenderedUnit, R::Error> {
    let mut unit = unit.clone();
    normalize_unit(&mut unit);
    Ok(match &unit {
        Unit::Compile(c) => RenderedUnit::Compile(RenderedCompile {
            package: c.package.clone(),
            krate: c.krate.clone(),
            platform: c.platform,
            program: c
                .program
                .iter()
                .map(|t| text(t, r))
                .collect::<Result<_, _>>()?,
            args: c
                .args
                .iter()
                .map(|a| {
                    Ok(match a {
                        Arg::Literal(s) => RenderedArg::Literal(s.clone()),
                        Arg::Concat(p) => RenderedArg::Literal(text(&Text::Concat(p.clone()), r)?),
                        Arg::Splice(s) => RenderedArg::Splice(splice(s, r)?),
                    })
                })
                .collect::<Result<_, _>>()?,
            env: env(&c.env, r)?,
            env_splices: c
                .env_splices
                .iter()
                .map(|s| splice(s, r))
                .collect::<Result<_, _>>()?,
            cwd: r.reference(&c.cwd)?,
            outputs: c
                .outputs
                .iter()
                .map(|(k, v)| (k.clone(), v.iter().cloned().collect()))
                .collect(),
        }),
        Unit::Run(run) => RenderedUnit::Run(RenderedRun {
            package: run.package.clone(),
            platform: run.platform,
            links: run.links.clone(),
            script: r.reference(&run.script)?,
            env: env(&run.env, r)?,
            cwd: r.reference(&run.cwd)?,
            metadata_from: run
                .metadata_from
                .iter()
                .map(|u| r.flags(u))
                .collect::<Result<_, _>>()?,
            rust_version: run.rust_version.clone(),
            targets: run.targets.clone(),
            nightly_features_allowed: run.nightly_features_allowed,
        }),
    })
}

/// The `BREAKBULK_UNIT` value: canonical JSON of a rendered unit.
pub fn unit_env_value(unit: &RenderedUnit) -> Result<String, CanonicalError> {
    to_canonical_json(unit)
}
