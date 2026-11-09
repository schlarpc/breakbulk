pub fn size(v: &[u8]) -> usize {
    v.to_vec().len()
}

pub fn none(v: &[u8]) -> bool {
    v.to_vec().is_empty()
}
