// app's build-script run is a target-platform unit: the target spec's env
// reaches it (as CC_<triple>, RC or LIB must for cross presets). Its
// compile, and everything it links (hostdep, shared), are host units.
fn main() {
    assert_eq!(
        std::env::var("BB_MARKER").as_deref(),
        Ok("target-only"),
        "a target-platform build-script run should see the target spec's env"
    );
    hostdep::touch();
    println!("cargo::rustc-env=SHARED_HOST={}", shared::platform());
}
