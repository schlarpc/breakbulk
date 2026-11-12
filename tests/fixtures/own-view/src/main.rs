// In app's own view: the root package's directory holds `assets/`.
const ASSETS: &str = include_str!(concat!(env!("BB_ASSETS"), "/data.txt"));
// In lib1's directory: app lists it in extraSources.
const LIB1_DATA: &str = include_str!(concat!(env!("BB_LIB1_DATA"), "/lib1.txt"));

fn main() {
    println!(
        "app: {} | {} | lib1: {} | {} | {}",
        ASSETS.trim(),
        LIB1_DATA.trim(),
        lib1::OWN.trim(),
        lib1::ASSETS.trim(),
        lib1::number(7),
    );
}
