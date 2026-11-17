fn main() {
    let header = "/nonexistent/breakbulk-dev-dep.h";
    println!("cargo::rerun-if-changed={header}");
    let found = if std::path::Path::new(header).exists() {
        "present"
    } else {
        "absent"
    };
    println!("cargo::rustc-env=TOOL={found}");
}
