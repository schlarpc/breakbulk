fn main() {
    println!("extra={}", feat::extra_enabled());
}

#[cfg(test)]
mod tests {
    #[test]
    fn dev_dependency_feature_is_on_in_tests() {
        assert!(feat::extra_enabled());
    }
}
