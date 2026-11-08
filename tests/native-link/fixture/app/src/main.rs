fn main() {
    println!("{}", mid::describe());
}

#[cfg(test)]
mod tests {
    #[test]
    fn links_and_runs() {
        assert!(mid::describe().starts_with("the answer is "));
    }
}
