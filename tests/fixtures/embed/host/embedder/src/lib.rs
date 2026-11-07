/// Another workspace's product, embedded at compile time. `PAYLOAD_BIN`
/// comes from `packages.embedder.env`.
pub static PAYLOAD: &[u8] = include_bytes!(env!("PAYLOAD_BIN"));
