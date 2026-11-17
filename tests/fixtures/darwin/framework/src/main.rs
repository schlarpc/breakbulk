fn main() {
    let n = framework::cf_length(c"breakbulk".as_ptr());
    println!("CoreFoundation counts {n}");
}
