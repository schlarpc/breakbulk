A repository path that reaches a git crate through Cargo config `[env]`
with `relative = true` (`app/.cargo/config.toml`): `envdep`'s build
script reads `$ENVDEP_DIR/answer.txt`. A crate outside the repository has
no source view, so the path points into an empty directory and the run
fails; the hint names `packages.envdep.env.ENVDEP_DIR`. envdep/ stands in
for the fetched git tree; the URL is never contacted.
