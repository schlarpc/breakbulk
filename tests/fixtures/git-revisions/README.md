Four workspaces (`a`, `b`, `c`, `d`) with their own lockfiles, all
depending on `gitdep` from one git repository at `file:///build/gitdep`.
`gitdep` depends on `gitbase` (a path dependency inside the repository,
with a build script). The repository has two commits on `main`: `repo-r1/`
and `repo-r2/`, which differ only in `gitdep`'s source.

- `a` and `c`: `branch = "main"`, locked at the first commit.
- `b`: `branch = "main"`, locked at the second commit.
- `d`: `rev = "<first commit>"`.
- `common/` is a path crate outside every workspace root.

tests/git-revisions makes the real repository (fixed dates, so the commit
ids are stable), checks that real Cargo writes these lockfiles against it,
and builds the workspaces with `gitTrees` pointing each locked source at
`repo-r1/` or `repo-r2/`.
