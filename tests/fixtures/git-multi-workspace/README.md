One git repository with two workspaces that both use workspace inheritance,
with other values for the same keys: repo/ (crates a, b; version 1.0.0,
edition 2021, readme and license-file) and repo/tools/ (crates c, d;
version 2.0.0, edition 2018, readme, license, description). consumer/
depends on a and c from the same git source, so one vendored source holds
crates from both workspaces. repo/ stands in for the fetched tree;
tests/git-multi-workspace commits it as file:///build/gitdep for real Cargo.
