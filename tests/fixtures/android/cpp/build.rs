fn main() {
    // CXX_<target>: presets.android's NDK clang++. The C++ runtime is
    // cc-rs's default for Android, c++_shared.
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("cxxsrc/words.cpp")
        .compile("words");
    println!("cargo:rerun-if-changed=cxxsrc/words.cpp");
}
