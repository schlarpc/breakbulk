// Prints the file names of argv[0] and of current_exe(), which
// tests/bin_exe.rs compares with the name Cargo gives the bin.
fn main() {
    let name = |p: std::path::PathBuf| p.file_name().unwrap().to_string_lossy().into_owned();
    println!("{}", name(std::env::args_os().next().unwrap().into()));
    println!("{}", name(std::env::current_exe().unwrap()));
}
