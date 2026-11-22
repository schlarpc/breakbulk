# Check docs/src/reference/assumptions.md against itself: the summary table
# has one row per `###` entry, in the same order, each linking to its
# entry's heading, and the status line counts the entries and the rows
# marked pinned (docs/default.nix, assumptionsSummary).
#
#   python3 assumptions-summary.py <assumptions.md>
import re
import sys
from pathlib import Path


# mdBook's heading ids (`normalize_id`): lower case, spaces as `-`, and only
# alphanumerics, `-` and `_` kept.
def anchor(heading):
    return "".join(
        c for c in heading.lower().replace(" ", "-") if c.isalnum() or c in "-_"
    )


def main(path):
    text = Path(path).read_text()
    headings = re.findall(r"^### ([A-Z]\d+)\. (.+)$", text, re.M)
    rows = re.findall(
        r"^\| \[([A-Z]\d+)\]\(#([^)]+)\) \| .+ \| ([^|]+) \|$", text, re.M
    )
    errors = []

    ids = [i for i, _ in headings]
    row_ids = [i for i, _, _ in rows]
    if ids != row_ids:
        missing = sorted(set(ids) - set(row_ids))
        extra = sorted(set(row_ids) - set(ids))
        errors.append(
            "the summary table's rows are not the entries in order"
            + (f"; no row for {', '.join(missing)}" if missing else "")
            + (f"; no entry for {', '.join(extra)}" if extra else "")
        )
    titles = dict(headings)
    for i, link, _ in rows:
        if i in titles and link != anchor(f"{i}. {titles[i]}"):
            errors.append(f"{i}: the row links to #{link}, not #{anchor(f'{i}. {titles[i]}')}")

    status = re.search(r"^Status of the (\d+) entries: (\d+) pinned", text, re.M)
    pinned = sum(1 for _, _, p in rows if p.strip().startswith("yes"))
    if not status:
        errors.append("no line `Status of the N entries: M pinned`")
    else:
        n, m = int(status.group(1)), int(status.group(2))
        if n != len(ids):
            errors.append(f"the status line counts {n} entries; there are {len(ids)}")
        if m != pinned:
            errors.append(f"the status line counts {m} pinned; {pinned} rows say yes")

    for e in errors:
        print(f"{path}: {e}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
