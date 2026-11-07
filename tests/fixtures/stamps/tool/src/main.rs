fn main() {
    println!("tool rev={} {}", option_env!("GIT_REV").unwrap_or("unset"), util::describe(1));
}
