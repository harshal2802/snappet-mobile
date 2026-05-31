# AppIcon

`AppIcon.png` — **Snappet "S" monogram**: bold rounded glyph (SF Rounded Black,
white) on a full-bleed coral→magenta diagonal gradient, with a soft drop shadow.

- 1024×1024 px, sRGB, **no alpha channel** (App Store requirement).
- Full-bleed — no rounded corners baked in; Xcode/`actool` applies the corner
  mask and generates every required size from this single source.

## Regenerating / trying other palettes

The icon is rendered natively (CoreGraphics + SF Rounded, no external deps) by
[`generate-icon.swift`](generate-icon.swift), which emits four palette variants:

```sh
swift generate-icon.swift /tmp/snappet-icons
# variants: A-orange-pink · B-coral-magenta (current) · C-sunset · D-violet-pink
cp /tmp/snappet-icons/snappet-B-coral-magenta.png AppIcon.png
```

Edit the `palettes` array in the script to tweak colors, or `roundedFont` /
shadow for the glyph treatment.
