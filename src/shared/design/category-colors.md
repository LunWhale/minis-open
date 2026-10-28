# Session category avatar colours

Reference for every platform's session-list category avatar: a 44 pt circle
filled with the category's **tint** at 18 % opacity (35 % on the open row),
with the category glyph on top in the **icon** colour.

Drawing the glyph in the tint colour itself (iOS's original SessionRow, which
iOS and Android keep) leaves light hues unreadable: systemYellow on its own
18 % tint is 1.11:1. On Windows the icon colours below keep the tint's HSL hue
and saturation and move only lightness (darker in light, lighter in dark) until
the glyph clears 2:1 against the circle composited over the
sidebar (`#f5f5f7` / `#161618`) and over the row selection fill (`#e5e5ea` /
`#2c2c2e`) at both 18 % and 35 %.

Tints are the iOS UIColor.system* values. Source of truth on Windows:
`src/windows/crates/minis-ui/src/sidebar/mod.rs` `category_ink()` (test
`category_avatars_stay_readable`), UI-261020-08, floor lowered from 3.3:1
to 2:1 in UI-261021-04 because the 3.3:1 glyphs looked too dark.

| System colour | Categories | Tint light | Icon light | Tint dark | Icon dark |
|---|---|---|---|---|---|
| Orange | code, travel | `#ff9500` | `#d47c00` | `#ff9f0a` | `#ff9f0a` |
| Blue | writing, education | `#007aff` | `#007aff` | `#0a84ff` | `#0a84ff` |
| Teal | research | `#30b0c7` | `#299bae` | `#40c8e0` | `#40c8e0` |
| Indigo | analysis | `#5856d6` | `#5856d6` | `#5e5ce6` | `#5f5de6` |
| Pink | creative, design | `#ff2d55` | `#ff0636` | `#ff375f` | `#ff375f` |
| Green | chat | `#34c759` | `#2ba64a` | `#30d158` | `#30d158` |
| Purple | math | `#af52de` | `#af52de` | `#bf5af2` | `#bf5af2` |
| Cyan | translation | `#32ade6` | `#1a98d2` | `#64d2ff` | `#64d2ff` |
| Red | health | `#ff3b30` | `#ff1f12` | `#ff453a` | `#ff453a` |
| Mint | finance | `#00c7be` | `#00a29b` | `#63e6e2` | `#63e6e2` |
| Yellow | productivity | `#ffcc00` | `#be9800` | `#ffd60a` | `#ffd60a` |
| Brown | support | `#a2845e` | `#a2845e` | `#ac8e68` | `#ac8e68` |
| Gray | other, uncategorised | `#8e8e93` | `#8b8b90` | `#98989d` | `#98989d` |

Worst-case glyph-vs-circle contrast after the change (open row, 35 % tint on
the selection fill): light 2.00-2.82, dark 2.00-3.97. Before any change: light
1.11-2.82, dark 1.98-3.97. Most hues keep their system colour.
