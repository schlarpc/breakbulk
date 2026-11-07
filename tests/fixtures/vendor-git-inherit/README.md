A git dependency whose crates use workspace inheritance (fields,
dependencies, lints, readme and license-file at a different depth than the
vendor layout). repo/ stands in for the fetched git tree (see tests/nix);
consumer/ depends on it through a git URL that is never contacted.
