use std::io::Write;

/// Serves the embedded files: with a path, writes that file to stdout
/// (exit 1 when there is none); without, lists every file.
fn main() {
    match std::env::args().nth(1) {
        Some(path) => match assets::Ui::get(&path) {
            Some(file) => std::io::stdout().write_all(&file.data).expect("writing the file"),
            None => {
                eprintln!("{}: no such file", other::NAME);
                std::process::exit(1);
            }
        },
        None => {
            let mut names: Vec<_> = assets::Ui::iter().collect();
            names.sort();
            for name in names {
                println!("{name}");
            }
        }
    }
}
