# Vaux app icon layers

Layer art for Icon Composer. Every SVG is a full 1024 × 1024 canvas with the
shape already in place, so layers line up when dropped in. Colors in the files
are only defaults; the real ones live in the icon.

The five center bars are the menu bar glyph (`Sources/StatusIcon.swift`, live
state) scaled up: same widths, spacing and heights, so the app icon and the
menu bar icon are one shape.

| File | What it is |
|---|---|
| `bars.svg` | The five voice bars |
| `side-bars.svg` | One quieter bar on each side, on the same spacing |

## The icon

The finished icon is `Sources/Vaux.icon`, built straight into the app
(`ASSETCATALOG_COMPILER_APPICON_NAME: Vaux`). It holds the colors, glass and
per-appearance settings; open it in Icon Composer
(`/Applications/Xcode-beta.app/Contents/Applications/Icon Composer.app`) to
edit, then rebuild. New layer art goes here first, then into the icon.
