# Module options

Every option of `mkRepository`, generated from the module declarations, in
four groups:

- [Repository-wide options](options/repository.md): `mode`, `ca`,
  `sysDefaults`, registries and git sources.
- [Workspace options](options/workspaces.md): `workspaces.<name>`, one
  Cargo workspace each.
- [Target options](options/targets.md): `targets.<triple>`, a target's
  toolchain for every workspace that builds it.
- [Package options](options/packages.md): `packages.<name>`, settings for
  one package's units.
