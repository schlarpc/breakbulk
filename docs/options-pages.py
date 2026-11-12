# Split nixosOptionsDoc's CommonMark into one page per option group, with
# each option's heading as code (docs/default.nix, optionsPages).
#
#   python3 options-pages.py <optionsCommonMark> <output dir>
import re
import sys
from pathlib import Path

PAGES = {
    "repository": ("Repository-wide options", "Settings for the whole repository."),
    "workspaces": ("Workspace options", "`workspaces.<name>`: one Cargo workspace each."),
    "targets": ("Target options", "`targets.<triple>`: a target's toolchain, for every workspace that builds it."),
    "packages": ("Package options", "`packages.<name>`: settings for one package's units."),
}


# nixos-render-docs renders options in parallel workers whose renderer keeps
# paragraph state between options, so how many blank lines open an option
# depends on which worker rendered it, and so on every other option. Runs of
# blank lines mean the same as one in CommonMark outside code blocks.
def tidy(body):
    lines, fence = [], None
    for line in body.splitlines():
        stripped = line.lstrip()
        if fence is None:
            if not stripped:
                if lines and lines[-1]:
                    lines.append("")
                continue
            if m := re.match(r"(`{3,})[^`]*$", stripped):
                fence = len(m.group(1))
        elif re.fullmatch(rf"`{{{fence},}}\s*", stripped):
            fence = None
        lines.append(line)
    return "\n".join(lines).strip("\n")


src, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
sections = {k: [] for k in PAGES}
for block in re.split(r"(?m)^(?=## )", src):
    if not block.startswith("## "):
        continue
    heading, rest = block.split("\n", 1)
    name = re.sub(r"\\(.)", r"\1", heading[3:].strip())
    group = name.split(".")[0]
    sections[group if group in PAGES else "repository"].append(f"## `{name}`\n\n{tidy(rest)}\n")
for key, (title, intro) in PAGES.items():
    note = "<!-- Generated from lib/modules by `nix run .#update-docs-options`; edit the option descriptions there. -->"
    (out / f"{key}.md").write_text(f"{note}\n\n# {title}\n\n{intro}\n\n" + "\n".join(sections[key]))
