// Built twice: as a target unit (a normal dependency of app) and as a host
// unit (a build dependency). Only the target unit gets the target rustflags.
pub fn platform() -> &'static str {
    if cfg!(bb_marker_flag) { "target" } else { "host" }
}
