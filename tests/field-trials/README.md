# Field trials

breakbulk modules for three of the author's repositories, used to try
breakbulk on real code. Findings are in `docs/field-trials.md` at the `spikes-archive` tag.

This directory holds no source from those repositories. Each trial is:

- `<name>/nix/rust.nix`: the module, written as the repository would carry it
  in place of its crane wiring. It receives `root` (the checkout),
  `breakbulk`, `pkgs` and `repo` (the repository object itself, for products
  used as inputs), which mkRepository gives every module.
- `<name>/outputs.nix`: what the repository's own flake builds, as
  attributes of the trial (`build`, plus named products and checks).

`default.nix` takes each checkout as an argument. A trial whose argument is
not given is left out.

## Running

Copy the repository to a directory outside `$HOME`, without build outputs or
secrets (`target/`, `result*`, `node_modules/`, `.env*`, keys):

```sh
rsync -a --exclude=/.git --exclude=target/ --exclude=node_modules/ \
  --exclude='result*' --exclude='.env*' --filter=':- .gitignore' \
  ~/datboi2/ /tmp/trials/datboi2/
```

Then build, from the breakbulk checkout:

```sh
nix build -f tests/field-trials --arg datboi2 /tmp/trials/datboi2 datboi2.build
nix build -f tests/field-trials --arg datboi2 /tmp/trials/datboi2 datboi2.checks
nix build -f tests/field-trials --arg kmsrsos /tmp/trials/kmsrsos kmsrsos.build
nix build -f tests/field-trials --arg mtgac /tmp/trials/mtgac mtgac.build
```

`<name>.repo` is the mkRepository result (plans, units, `explainSharing`).

The trials use IFD mode and the flake's pinned nixpkgs and rust-overlay.
Each repository's toolchain comes from its own `rust-toolchain.toml`.
kmsrsos and mtgac download the xwin SDK (unfree, about 250 MB) for their
Windows targets.

These are not flake checks: they need checkouts that are not in this
repository.
