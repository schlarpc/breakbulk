# Split nixosOptionsDoc's CommonMark into one page per option group under
# reference/options/, with each option's heading as code.
#
#   python3 options-pages.py <optionsCommonMark> <book src dir>
import re
import sys
from pathlib import Path

PAGES = {
    "repository": ("Repository-wide options", "Settings for the whole repository."),
    "workspaces": ("Workspace options", "`workspaces.<name>`: one Cargo workspace each."),
    "targets": ("Target options", "`targets.<triple>`: a target's toolchain, for every workspace that builds it."),
    "packages": ("Package options", "`packages.<name>`: settings for one package's units."),
}

src, out = Path(sys.argv[1]).read_text(), Path(sys.argv[2]) / "reference" / "options"
out.mkdir(parents=True, exist_ok=True)
sections = {k: [] for k in PAGES}
for block in re.split(r"(?m)^(?=## )", src):
    if not block.startswith("## "):
        continue
    heading, rest = block.split("\n", 1)
    name = re.sub(r"\\(.)", r"\1", heading[3:].strip())
    group = name.split(".")[0]
    sections[group if group in PAGES else "repository"].append(f"## `{name}`\n{rest}")
for key, (title, intro) in PAGES.items():
    (out / f"{key}.md").write_text(f"# {title}\n\n{intro}\n\n" + "".join(sections[key]))
