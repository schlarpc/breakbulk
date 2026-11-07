fn main() {
    println!(
        "app rev={} epoch={} {}",
        option_env!("GIT_REV").unwrap_or("unset"),
        env!("SOURCE_DATE_EPOCH"),
        util::describe(42)
    );
}
