# Design files

| File | What it is |
|---|---|
| `icon.png` | Source artwork of the app icon, 1024×1024. `scripts/make-icon.sh` turns it into `App/Assets.xcassets/AppIcon.appiconset` (see "App icon" in `CLAUDE.md`). |
| `render-icon.swift` | Script that draws `icon.png`. |

## The app icon

An upright battery on a cream base, in the flat style of the author's Piccolo icon and with its palette: cream
`#F7EBD7`, brown `#5F4234`, and a green `#5BBE6E` as light and saturated as Piccolo's blue. The battery's inside is
split like Piccolo's glass: an empty top pane, a brown gutter at the 80 % charge limit, and a green pane below it.

- The base is Apple's macOS icon grid: an 824 px continuous rounded square (corner radius 185.4 px) at 100 px on the
  1024 px canvas, transparent outside.
- The battery body is 360 × 540 px with a 40 px outline, plus a 160 × 44 px terminal on top; the group is centred
  10 px above the canvas centre, with a soft floor shadow under it.
- The green pane sits 14 px inside the outline; the gutter is 36 px, centred at 80 % of the inside's height from the
  bottom.

## Changing the icon

Edit `render-icon.swift`, then:

```sh
swift design/render-icon.swift     # writes design/icon.png
scripts/make-icon.sh --normalize   # regenerates App/Assets.xcassets/AppIcon.appiconset
scripts/build.sh release
scripts/check-icon-render.sh       # the icon the system draws matches the artwork
```

`--normalize` sets the alpha of the anti-aliased rim pixels at 240 or more to 255, so the committed `icon.png` is that
normalized render, not the script's raw output.
