//! How planner errors name units: the id, which the plan file and
//! `explainSharing` use, followed by what the unit is, which a reader can
//! find without Cargo's verbose log.

use breakbulk_format::rendered::package_name_version;
use breakbulk_format::{Arg, Platform, Unit};

/// A compile: `unit c-… (block-buffer 0.10.4, lib, target)`. A `--test`
/// compile's kind is `test`; the crate name follows the kind when it is
/// not the package's (`bin cli`, `test datadriven`).
pub fn compile(
    id: &str,
    package: &str,
    version: &str,
    krate: &str,
    types: &[String],
    test: bool,
    platform: Platform,
) -> String {
    let kind = if test {
        "test".to_owned()
    } else {
        types.join("+")
    };
    let name = if krate == package.replace('-', "_") {
        String::new()
    } else {
        format!(" {krate}")
    };
    format!(
        "unit {id} ({}, {kind}{name}, {})",
        package_version(package, version),
        platform_name(platform)
    )
}

/// A build-script run: `run r-ring-… (build script of ring 0.17.14, host)`.
pub fn run(id: &str, package: &str, version: &str, platform: Platform) -> String {
    format!(
        "run {id} (build script of {}, {})",
        package_version(package, version),
        platform_name(platform)
    )
}

/// A doctest: `doctest d-app (app 0.1.0)`.
pub fn doctest(id: &str, package: &str, version: &str) -> String {
    format!("doctest {id} ({})", package_version(package, version))
}

/// [`compile`] or [`run`] for a unit of a plan.
pub fn unit(id: &str, u: &Unit) -> String {
    match u {
        Unit::Compile(c) => {
            let (name, version) = name_version(&c.package);
            let test = c
                .args
                .iter()
                .any(|a| matches!(a, Arg::Literal(s) if s == "--test"));
            compile(
                id,
                name,
                version,
                &c.krate.name,
                &c.krate.types,
                test,
                c.platform,
            )
        }
        Unit::Run(r) => {
            let (name, version) = name_version(&r.package);
            run(id, name, version, r.platform)
        }
    }
}

/// Per-unit errors, one line per cause: the units it concerns, then the
/// cause, in the order the causes first occur.
pub fn grouped(errors: impl IntoIterator<Item = (String, String)>) -> Vec<String> {
    let mut causes: Vec<(String, Vec<String>)> = Vec::new();
    for (subject, cause) in errors {
        match causes.iter_mut().find(|(c, _)| *c == cause) {
            Some((_, subjects)) => subjects.push(subject),
            None => causes.push((cause, vec![subject])),
        }
    }
    causes
        .into_iter()
        .map(|(cause, subjects)| format!("{}: {cause}", subjects.join(", ")))
        .collect()
}

fn name_version(id: &str) -> (&str, &str) {
    package_name_version(id).unwrap_or((id, ""))
}

fn package_version(package: &str, version: &str) -> String {
    if version.is_empty() {
        package.to_owned()
    } else {
        format!("{package} {version}")
    }
}

/// `host` or `target`.
pub fn platform_name(p: Platform) -> &'static str {
    match p {
        Platform::Host => "host",
        Platform::Target => "target",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forms() {
        let types = |t: &[&str]| t.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            compile(
                "c-a99789a5b8158e0a",
                "block-buffer",
                "0.10.4",
                "block_buffer",
                &types(&["lib"]),
                false,
                Platform::Target
            ),
            "unit c-a99789a5b8158e0a (block-buffer 0.10.4, lib, target)"
        );
        assert_eq!(
            compile(
                "c-1",
                "app",
                "0.1.0",
                "build_script_build",
                &types(&["bin"]),
                false,
                Platform::Host
            ),
            "unit c-1 (app 0.1.0, bin build_script_build, host)"
        );
        assert_eq!(
            compile(
                "c-2",
                "proto",
                "0.1.0",
                "datadriven",
                &types(&["bin"]),
                true,
                Platform::Target
            ),
            "unit c-2 (proto 0.1.0, test datadriven, target)"
        );
        assert_eq!(
            run("r-ring-1f", "ring", "0.17.14", Platform::Host),
            "run r-ring-1f (build script of ring 0.17.14, host)"
        );
    }

    #[test]
    fn repeats_grouped() {
        let e = |s: &str, c: &str| (s.to_owned(), c.to_owned());
        assert_eq!(
            grouped([
                e("unit c-1 (a 1, lib, target)", "no run `x`"),
                e("unit c-2 (b 1, lib, target)", "no run `y`"),
                e("unit c-3 (c 1, lib, target)", "no run `x`"),
            ]),
            [
                "unit c-1 (a 1, lib, target), unit c-3 (c 1, lib, target): no run `x`",
                "unit c-2 (b 1, lib, target): no run `y`",
            ]
        );
    }
}
