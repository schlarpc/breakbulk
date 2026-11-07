# Logo

The breakbulk badge: the Nix λ as a jib crane, with one braced crate hanging
from its tip, cut out of a solid hexagon. Break-bulk cargo is loaded piece by
piece; breakbulk builds a Rust project one Cargo unit at a time.

| File | Use |
| --- | --- |
| `breakbulk.svg` | Light backgrounds: navy hexagon, white λ, rust crate |
| `breakbulk-dark.svg` | Dark backgrounds: light hexagon, dark λ, lighter rust crate |
| `generate.py` | Writes both SVGs. Edit the constants at the top and rerun it |

Construction:

- The λ is the NixOS snowflake's λ, point for point, only scaled.
- The cable and crate swing 30° off vertical, so every angle in the mark is a
  multiple of 30°.
- The crate is one path with its two openings cut out (`fill-rule="evenodd"`),
  so the frame and brace show no seams, and the hexagon shows through.
- The mark is centred by visual weight, not by bounding box. `layout()` in
  `generate.py` has the rule.

## Credit and status

The λ is derived from the NixOS snowflake by Simon Frankau and Tim
Cuthbertson, from [NixOS/nixos-artwork](https://github.com/NixOS/nixos-artwork/tree/master/logo),
licensed [CC-BY 4.0](https://creativecommons.org/licenses/by/4.0/). Changes:
one λ taken from the snowflake, scaled, and combined with a crate and a
hexagon.

CC-BY covers copyright only. NixOS registered a trademark in 2026, and its
trademark policy is not yet published. The [NixOS branding guide](https://brand.nixos.org/documents/nixos-branding-guide.pdf)
asks that the logo and its components not be altered. Ask the NixOS Marketing
Team before using this mark outside the project's own repository.
