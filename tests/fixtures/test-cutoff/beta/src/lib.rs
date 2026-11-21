pub fn beta() -> u32 {
    1
}

// alpha's test never calls this. The cutoff tests edit its body and move
// it down: the edit reaches only beta's debug info.
pub fn unused() -> u32 {
    2
}
