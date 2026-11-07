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

#[cfg(test)]
mod tests {
    #[test]
    fn build_script_reached_the_test_harness() {
        assert!(cfg!(walking_skeleton));
        assert_eq!(env!("WS_FROM_BUILD"), "hello-from-build-script");
        assert_eq!(super::generated::ANSWER, 42);
    }
}
