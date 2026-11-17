fn main() {
    println!("app {} {}", env!("SHARED_VERSION"), dep::TOOL);
}

#[cfg(test)]
mod tests {
    #[test]
    fn probes() {
        assert_eq!(devdep::TOOL, "absent");
        assert_eq!(env!("HOST_TOOL"), "absent");
    }
}
