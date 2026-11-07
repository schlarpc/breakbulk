fn main() {
    println!(
        "spec={} key={} build={}",
        cfg!(bb_spec),
        cfg!(bb_key),
        cfg!(bb_build)
    );
}
