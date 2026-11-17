//! Hints for a unit of a registry or git package that fails while one of
//! its env values or arguments names a repository path
//! ([`RepositoryPath`]): Cargo config `[env]` with `relative = true`, or
//! `build.rustflags`. Such a package has no source view, so the path
//! points into an empty directory. The hint does not depend on the
//! failure's message: the script or rustc may report the missing
//! directory in any words, or not at all.

use breakbulk_hints::option_prefix;

use crate::spec::{RepositoryPath, package_name_version};

/// One hint line per entry of `paths`.
pub fn hints(package: &str, paths: &[RepositoryPath]) -> Vec<String> {
    let name = package_name_version(package).map_or(package, |(n, _)| n);
    let opt = option_prefix(package);
    paths
        .iter()
        .map(|p| {
            let path = if p.path.is_empty() { "." } else { &p.path };
            let given = format!("`{name}` was given the repository path `{path}`");
            let unseen = "registry and git crates do not see the repository";
            match (&p.env, &p.arg) {
                (_, Some(arg)) => {
                    let place = match &p.env {
                        Some(var) => format!("`{arg}` in `{var}`"),
                        None => format!("the rustc argument `{arg}`"),
                    };
                    format!(
                        "{given} in {place} (from Cargo config `build.rustflags`); {unseen}, \
                         and no per-package option changes that argument"
                    )
                }
                (Some(var), None) if p.whole => format!(
                    "{given} in `{var}` (from Cargo config `[env]`); {unseen}: set \
                     `{opt}.env.{var} = ./{path};`"
                ),
                (Some(var), None) => format!(
                    "{given} in `{var}` (from Cargo config `[env]`); {unseen}: set \
                     `{opt}.env.{var}` to a value with `./{path}` in its place"
                ),
                (None, None) => format!("{given}; {unseen}"),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const OPENSSL: &str = "registry+https://github.com/rust-lang/crates.io-index#openssl-sys@0.9.0";

    fn path(path: &str, env: Option<&str>, whole: bool, arg: Option<&str>) -> RepositoryPath {
        RepositoryPath {
            path: path.into(),
            env: env.map(Into::into),
            whole,
            arg: arg.map(Into::into),
        }
    }

    #[test]
    fn env_value() {
        assert_eq!(
            hints(
                OPENSSL,
                &[path("vendor/openssl", Some("OPENSSL_DIR"), true, None)]
            ),
            [
                "`openssl-sys` was given the repository path `vendor/openssl` in `OPENSSL_DIR` \
                 (from Cargo config `[env]`); registry and git crates do not see the \
                 repository: set `packages.openssl-sys.env.OPENSSL_DIR = ./vendor/openssl;`"
            ]
        );
        let h = hints(OPENSSL, &[path("", Some("ROOT"), false, None)]);
        assert!(
            h[0].ends_with(
                "set `packages.openssl-sys.env.ROOT` to a value with `./.` in its place"
            ),
            "{h:?}"
        );
    }

    #[test]
    fn argument() {
        let h = hints(
            OPENSSL,
            &[
                path("vendor/lib", None, false, Some("-L native=vendor/lib")),
                path(
                    "vendor/lib",
                    Some("CARGO_ENCODED_RUSTFLAGS"),
                    false,
                    Some("-L native=vendor/lib"),
                ),
            ],
        );
        assert_eq!(
            h[0],
            "`openssl-sys` was given the repository path `vendor/lib` in the rustc argument \
             `-L native=vendor/lib` (from Cargo config `build.rustflags`); registry and git \
             crates do not see the repository, and no per-package option changes that argument"
        );
        assert!(
            h[1].contains("in `-L native=vendor/lib` in `CARGO_ENCODED_RUSTFLAGS`"),
            "{h:?}"
        );
    }
}
