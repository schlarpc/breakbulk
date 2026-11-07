"""Diffs results/placement-*.txt across toolchains after removing hashes and paths."""

import difflib
import re
import sys
from pathlib import Path

HERE = Path(__file__).parent


def normalized(p: Path):
    out = []
    for line in p.read_text().splitlines():
        if line.strip().startswith("printed:") or line.startswith("##"):
            continue
        line = re.sub(r"[0-9a-fA-F]{16}", "H", line)
        line = re.sub(r"/tmp/\S*", "", line)
        out.append(line)
    return out


def main(argv):
    files = sorted((HERE / "results").glob("placement-*.txt"))
    base = files[0]
    for f in files[1:]:
        d = list(difflib.unified_diff(normalized(base), normalized(f), base.name, f.name, lineterm="", n=0))
        print(f"{base.name} vs {f.name}: {'identical' if not d else 'DIFFERENT'}")
        for line in d:
            print("  " + line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
