mod generated {
    include!(concat!(env!("OUT_DIR"), "/generated.rs"));
}

fn main() {
    let mut buf = itoa::Buffer::new();
    let answer = buf.format(generated::ANSWER);
    let cfg = if cfg!(walking_skeleton) {
        "cfg-on"
    } else {
        "cfg-off"
    };
    println!(
        "walking-skeleton {answer} {cfg} {} {}",
        env!("WS_FROM_BUILD"),
        generated::PROFILE
    );
}
