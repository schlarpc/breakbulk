/// `env`: the `[env]` variable at compile time; `cfg`: `build.rustflags`
/// from the variant's config; `spec`: the target's own rustflags. With
/// `panic`, it panics: exit status 101 when unwinding, an abort with
/// `panic = "abort"`.
fn main() {
    if std::env::args().nth(1).as_deref() == Some("panic") {
        panic!("asked to");
    }
    println!(
        "env={} cfg={} spec={} dep={}",
        option_env!("FROM_CARGO_CONFIG").unwrap_or("none"),
        cfg!(from_cargo_config),
        cfg!(from_spec),
        dep::value()
    );
}

#[cfg(test)]
mod tests {
    /// Cargo's `[env]` reaches test processes too.
    #[test]
    fn cargo_config_env_at_run_time() {
        let want = if cfg!(from_cargo_config) {
            Some("dist")
        } else {
            None
        };
        assert_eq!(std::env::var("FROM_CARGO_CONFIG").ok().as_deref(), want);
        assert!(cfg!(from_spec));
    }
}
