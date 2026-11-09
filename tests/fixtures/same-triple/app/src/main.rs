// Target units get the spec's rustflags and the project's,
// and the spec's env.
#[cfg(not(project_flag))]
compile_error!("the project's [build] rustflags did not reach a target unit");
#[cfg(not(bb_marker_flag))]
compile_error!("the target spec's rustflags did not reach a target unit");

pm::assert_host_clean!();

fn main() {
    println!(
        "marker={} shared={} shared-in-build-script={}",
        env!("BB_MARKER"),
        shared::platform(),
        env!("SHARED_HOST")
    );
}

#[cfg(test)]
mod tests {
    #[test]
    fn target_sees_markers() {
        assert_eq!(env!("BB_MARKER"), "target-only");
        assert_eq!(shared::platform(), "target");
    }
}
