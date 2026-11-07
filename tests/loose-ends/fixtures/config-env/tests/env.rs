use std::path::Path;

#[test]
fn plain() {
    assert_eq!(std::env::var("BB_PLAIN").unwrap(), "plain-value");
    assert_eq!(config_env::PLAIN_AT_COMPILE, "plain-value");
}

#[test]
fn relative() {
    let p = std::env::var("BB_REL").unwrap();
    assert!(Path::new(&p).is_absolute(), "{p}");
    assert!(p.ends_with("/data/greeting.txt"), "{p}");
    assert_eq!(std::fs::read_to_string(&p).unwrap(), "hello from data\n");
    assert_eq!(p, config_env::REL_AT_COMPILE);
    assert_eq!(config_env::greeting(), "hello from data\n");
}

#[test]
fn forced() {
    assert_eq!(std::env::var("HOME").unwrap(), "/forced-home");
    assert_eq!(config_env::HOME_AT_COMPILE, "/forced-home");
}

#[test]
fn not_forced() {
    assert_ne!(std::env::var("PATH").ok().as_deref(), Some("/not-forced-path"));
    assert_ne!(config_env::PATH_AT_COMPILE, Some("/not-forced-path"));
}
