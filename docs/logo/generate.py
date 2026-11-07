#!/usr/bin/env python3
"""Generate the breakbulk badge SVGs in this directory.

The mark is the Nix λ used as a jib crane: a braced crate hangs from the λ's
tip on a cable swung 30° off vertical, all knocked out of a solid hexagon.

Run from anywhere: `python3 docs/logo/generate.py`. It rewrites
breakbulk.svg and breakbulk-dark.svg next to itself.
"""

import math
from pathlib import Path

# The λ from the NixOS snowflake (nixos-artwork, logo/nix-snowflake-colours.svg,
# CC-BY 4.0), translated so its bounding box starts at the origin. Points are
# unchanged otherwise.
LAMBDA = [
    (41.633, 0),
    (163.83, 211.675),
    (107.673, 212.202),
    (75.049, 155.333),
    (42.193, 211.898),
    (14.291, 211.887),
    (0, 187.198),
    (46.810, 106.708),
    (13.581, 48.882),
]
TIP = 8  # left end of the λ's top cut: where the cable hangs from

SCALE = 0.155  # λ size within the 64-unit view box
SWING = 30  # cable angle from vertical, degrees; on the λ's 30°/60° grid
CABLE = 10  # cable length
CRATE = 11.5  # crate side
NUDGE = (0.6, 0.4)  # cable anchor, tucked just inside the tip
HEX_RADIUS = 30

PALETTES = {
    "breakbulk.svg": {"hex": "#1f2a36", "lambda": "#ffffff", "crate": "#c2511f"},
    "breakbulk-dark.svg": {"hex": "#d9e1e8", "lambda": "#141a20", "crate": "#e2733f"},
}


def fmt(x):
    return f"{x:.2f}".rstrip("0").rstrip(".")


def points(ps):
    return " ".join(f"{fmt(x)},{fmt(y)}" for x, y in ps)


def place_lambda(tx, ty):
    return [(x * SCALE + tx, y * SCALE + ty) for x, y in LAMBDA]


def hang(lam):
    """Cable anchor, cable end, and the crate's corners for a placed λ."""
    ax, ay = lam[TIP][0] + NUDGE[0], lam[TIP][1] + NUDGE[1]
    a = math.radians(SWING)
    ex, ey = ax - CABLE * math.sin(a), ay + CABLE * math.cos(a)
    w = CRATE

    def rot(x, y):
        dx, dy = x - ex, y - ey
        return (ex + dx * math.cos(a) - dy * math.sin(a), ey + dx * math.sin(a) + dy * math.cos(a))

    corners = [rot(ex - w / 2, ey), rot(ex + w / 2, ey), rot(ex + w / 2, ey + w), rot(ex - w / 2, ey + w)]
    return (ax, ay), (ex, ey), corners


def centroid(poly):
    """Area and centroid of a simple polygon."""
    area = cx = cy = 0.0
    for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
        c = x1 * y2 - x2 * y1
        area += c
        cx += (x1 + x2) * c
        cy += (y1 + y2) * c
    area /= 2
    return abs(area), cx / (6 * area), cy / (6 * area)


def crate_ink():
    """Painted area of the crate: frame plus brace."""
    sw = CRATE * 0.17
    inner = CRATE - 2 * sw
    return CRATE * CRATE - inner * inner + inner * sw * 1.05 * math.sqrt(2)


def layout():
    """Offset for the λ that balances λ + crate inside the hexagon.

    Horizontally the ink's centre of mass sits on the hexagon's centre; the
    solid λ outweighs the crate frame, so centring the bounding box leaves the
    mark heavy on the right. Vertically the mark sits halfway between the
    bounding-box centre and the ink centre: the λ's feet pull the ink centre
    low, and centring on it fully lifts the mark too high.
    """
    lam = place_lambda(0, 0)
    _, _, crate = hang(lam)
    xs = [p[0] for p in lam + crate]
    ys = [p[1] for p in lam + crate]
    tx = 32 - (min(xs) + max(xs)) / 2
    ty = 32 - (min(ys) + max(ys)) / 2

    lam = place_lambda(tx, ty)
    _, _, crate = hang(lam)
    la, lx, ly = centroid(lam)
    ca = crate_ink()
    qx = sum(p[0] for p in crate) / 4
    qy = sum(p[1] for p in crate) / 4
    tx += 32 - (la * lx + ca * qx) / (la + ca)
    ty += (32 - (la * ly + ca * qy) / (la + ca)) / 2
    return tx, ty


def crate_path(x, y, w):
    """A braced crate as one evenodd path, so frame and brace share no edges."""
    sw = w * 0.17
    r = w * 0.05
    d = (
        f"M{fmt(x + r)} {fmt(y)}H{fmt(x + w - r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x + w)} {fmt(y + r)}"
        f"V{fmt(y + w - r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x + w - r)} {fmt(y + w)}"
        f"H{fmt(x + r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x)} {fmt(y + w - r)}"
        f"V{fmt(y + r)}A{fmt(r)} {fmt(r)} 0 0 1 {fmt(x + r)} {fmt(y)}Z"
    )
    i, inner, b = sw, w - 2 * sw, sw * 1.05
    X, Y = x + i, y + i
    d += f"M{fmt(X)} {fmt(Y)}H{fmt(X + inner - b)}L{fmt(X)} {fmt(Y + inner - b)}Z"
    d += f"M{fmt(X + inner)} {fmt(Y + b)}V{fmt(Y + inner)}H{fmt(X + b)}Z"
    return d


def badge(colors):
    hexagon = [
        (32 + HEX_RADIUS * math.cos(math.radians(60 * i + 30)), 32 + HEX_RADIUS * math.sin(math.radians(60 * i + 30)))
        for i in range(6)
    ]
    tx, ty = layout()
    lam = place_lambda(tx, ty)
    (ax, ay), (ex, ey), _ = hang(lam)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-labelledby="title">
  <title id="title">breakbulk</title>
  <!-- λ from the NixOS snowflake by Simon Frankau and Tim Cuthbertson, CC-BY 4.0
       (github.com/NixOS/nixos-artwork, logo/). Modified: single λ, scaled, crate and hexagon added. -->
  <polygon fill="{colors['hex']}" points="{points(hexagon)}"/>
  <polygon fill="{colors['lambda']}" points="{points(lam)}"/>
  <line stroke="{colors['lambda']}" stroke-width="1.6" x1="{fmt(ax)}" y1="{fmt(ay)}" x2="{fmt(ex)}" y2="{fmt(ey)}"/>
  <path fill="{colors['crate']}" fill-rule="evenodd" transform="rotate({SWING} {fmt(ex)} {fmt(ey)})" d="{crate_path(ex - CRATE / 2, ey, CRATE)}"/>
</svg>
"""


def main():
    here = Path(__file__).resolve().parent
    for name, colors in PALETTES.items():
        (here / name).write_text(badge(colors))


if __name__ == "__main__":
    main()
