# smthz app icon (Liquid Glass, Icon Composer)

Built 2026-10-25 from the reference artwork `icon/icon.png` (read-only, untouched). Background research: `docs/ICON-RESEARCH.md`.

## What was built

| Path | What |
|---|---|
| `assets/AppIcon/smthz.icon/` | Icon Composer document (folder package): `icon.json` + `Assets/` |
| `assets/AppIcon/smthz.icon/Assets/figure.png` | Bust (head, suit, shirt, tie, sunglasses, earpiece) as a 1024 px transparent PNG, scaled inside the system squircle |
| `assets/AppIcon/smthz.icon/Assets/rings.svg` | The 5 broken arcs around the head, vector (white stroke, round caps) |
| `assets/AppIcon/smthz.icon/Assets/dashes.svg` | The 13 vertical dashes/dots (4 columns), vector rounded rects |
| `assets/AppIcon/tools/extract_layers.swift` | Deterministic layer extraction from `icon/icon.png` (CoreGraphics/ImageIO only) |
| `assets/AppIcon/tools/render_previews.sh` | Exports the flat previews with `ictool` |
| `assets/AppIcon/previews/smthz-<Rendition>.png` | 1024 x 1024 flat previews: Default, Dark, ClearLight, ClearDark, TintedLight, TintedDark, Mono |
| `assets/AppIcon/previews/smthz-<Rendition>-before.png` | Recreated pre-tune previews for the same seven renditions, using the initial extraction geometry and fill/opacity values |
| `assets/AppIcon/previews/dock-light.png`, `dock-dark.png` | Earlier Dock screenshots; the 2026-10-25 follow-up Dock capture was temporary at `/tmp/icn/dock.png` and removed during cleanup |
| `scripts/package-app.sh` | Compiles the `.icon` with `actool` into the app bundle |

### Layer structure (`icon.json`)

- **Background:** the document fill, a diagonal grey linear gradient (no image). Default `extended-gray` 0.30 to 0.055; Dark 0.135 to 0.008 (`fill-specializations`).
- **Group "Figure"** (frontmost): `figure.png`, Liquid Glass on, specular on, individual lighting, neutral shadow 0.5, translucency off.
- **Group "Rings"** (behind the figure): `dashes.svg` and `rings.svg`, Liquid Glass on, specular on, combined lighting, neutral shadow 0.4, translucency 0.4. Opacity per appearance (`opacity-specializations`): dashes 0.55 / dark 0.8 / tinted 0.9; rings 0.62 / dark 0.82 / tinted 0.9.
- Platform: `"supported-platforms": {"squares": ["macOS"]}`.

Appearances: Icon Composer's document has three annotation slots, **Default**, **Dark** and **Mono** (key `tinted`). macOS derives the Clear (light/dark) and Tinted (light/dark) renditions from the Mono slot plus the system's glass/tint; there is no separate "clear" key in the format (checked: the only appearance strings in `IconComposerFoundation` are `dark`, `light`, `tinted`).

### How the layers were cut (extract_layers.swift)

1. The reference tile (source px x 80..1174, y 78..1172; the baked rim, gloss and black matte) maps onto the 1024 canvas. The baked tile itself is not reused: the system applies the mask and the glass.
2. **Figure:** a hand-measured polygon masks the bust. The output is scaled to 84% and centred so the figure sits inside the system squircle with side and lower margins. Rounded lower contour points soften the source's tile-edge cut; where the reference's glass rim crosses the suit, the shirt/tie band is extended and the jacket fades into a flat suit tone.
3. **Rings/dashes:** pixels at least 28 levels brighter than their 81 x 81 local mean (a top-hat, which ignores the smooth gloss), outside the dilated figure, are grouped into connected blobs. Thin vertical blobs become dashes (bounding box -> capsule). Long blobs are arcs: one shared least-squares circle (centre 625.7, 597.4 source px), blobs merged when their angular ranges touch, per-arc median radius, stroke width = median radial thickness (25.2 canvas px; cross-checked by hand: the left arc is 26-27 source px wide on row 560).
4. Output is byte-identical between runs (checked with md5 on two consecutive runs).

Debug: `SMTHZ_ICON_DEBUG=/path/debug.png` writes the reference with the detected pixels in red and the figure mask tinted blue.

## How to edit

- **In Icon Composer** (Xcode 27.1: `/Applications/Xcode.app/Contents/Applications/Icon Composer.app`): `open -a "Icon Composer" assets/AppIcon/smthz.icon`. Change glass, opacity, fill or per-appearance values and save; Icon Composer rewrites `icon.json` in place.
- **By hand:** edit `icon.json` (keys listed above; the format is undocumented by Apple, the keys used here are the ones Icon Composer and `actool` accept).
- **Layer artwork:** change the constants at the top of `extract_layers.swift` (crop square, figure polygon, clean area, detection threshold/window) and regenerate. Note that regenerating overwrites `Assets/figure.png`, `rings.svg` and `dashes.svg`.

## How to rebuild

```sh
# 1. Layers (only when the artwork or the extraction constants change)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift assets/AppIcon/tools/extract_layers.swift icon/icon.png assets/AppIcon/smthz.icon/Assets
# 2. Previews
assets/AppIcon/tools/render_previews.sh
# 3. App bundle (Assets.car + smthz.icns + CFBundleIconName)
scripts/package-app.sh            # optional: SMTHZ_SCRATCH_PATH=.build-xyz
```

`scripts/package-app.sh` still builds the old iconutil `.icns` from `icon/icon.png` first. It then runs `actool --app-icon smthz --platform macosx --minimum-deployment-target 26.0` on `assets/AppIcon/smthz.icon`. On success it copies `Assets.car` and actool's generated `smthz.icns` (made from the Liquid Glass icon) into `Contents/Resources` and adds `CFBundleIconName = smthz` to `Info.plist` (`CFBundleIconFile = smthz` stays). If actool fails it prints a warning plus the actool log and keeps the iconutil `.icns` without `CFBundleIconName`. `SMTHZ_SCRATCH_PATH` and ad-hoc signing are unchanged.

## How it was verified

- `ictool` rendered all 7 renditions without errors (previews in `assets/AppIcon/previews/`); reviewed visually next to `icon/icon.png`.
- Icon Composer GUI: opened `smthz.icon`, confirmed the document window was frontmost, reviewed its layer composition, and saved with Cmd-S after the artwork update. The save normalised the hand-authored document; the final numeric fill and ring opacity values were then applied in `icon.json` and validated by `ictool`/`actool`. The visible tile has a system generated glass rim; the bust and the five concentric broken arcs are inside the squircle.
- `actool` (standalone run): exit 0, no warnings/notices; produced `Assets.car`, `smthz.icns`, partial plist.
- `SMTHZ_SCRATCH_PATH=.build-icon2 scripts/package-app.sh`: release build succeeded; `Assets.car` (3.26 MB), actool `smthz.icns`, and both `CFBundleIconName` / `CFBundleIconFile` are present; `codesign --verify --deep --strict` and `plutil -lint` pass. `assetutil --info` lists Aqua, Dark Aqua, and Tintable appearances.
- Real Dock: started a private `smthzd` on `/tmp/icn/h.sock`, launched `build/smthz.app` with that socket, and captured `/tmp/icn/dock.png`. The Dock showed the new icon and the app showed “Local host connected”. Then stopped the host and app and removed `/tmp/icn` and `.build-icon2`.
- Packaged UI resources: `Contents/Resources/Icons` includes the SVGs and `Fonts/Geist-Variable.ttf`; direct AppKit checks decoded `activity.svg`, `panel-left.svg`, and `plus.svg` as `NSImage`, and CoreText registered Geist. `SmthzIcon.svgSource` resolves `Bundle.main.resourceURL/Icons/<name>.svg` before its SF Symbol fallback, so the packaged path is valid. No changes to `SmthzIcon.swift` or `SmthzFont.swift` were needed.
- Before/after preview files: `smthz-Default-before.png` and `smthz-Dark-before.png` recreate the prior scale-1 composition; their after counterparts are `smthz-Default.png` and `smthz-Dark.png`. All seven `-before.png` files were regenerated from the recorded initial extraction settings and JSON values because the original preview files were overwritten during iteration.

### Not verified

- Clear and Tinted styles in the real Dock/Finder (requires changing the system "Icon & widget style"; only the `ictool` renditions were checked).
- Whether the Dock switched to the Dark rendition was not tested in this pass; this capture used the current system appearance.
- Finder, Spotlight and 16/32 px legibility were not checked separately.
- Icon Composer's Apple page says `.icon` support needs macOS 26.4+, `LSMinimumSystemVersion` is 26.0; on older systems the generated `smthz.icns` is the fallback (not tested on an older OS).

## Divergences from the reference

- The baked glass tile (rim highlight, diagonal gloss streaks, black matte outside the corners) is gone by design; the system squircle and Liquid Glass replace it. The tile interior becomes a clean grey gradient.
- Rings and dashes are vector re-creations fitted to the reference pixels, not cut-outs: uniform stroke width and perfectly round caps; the faint bright edges of the reference strokes come from the system specular instead.
- The bottom and lower sides of the suit are reconstructed where the reference tile cropped the source: the shirt/tie are extended and the jacket fades into a flat dark grey. At full size, the polygon mask remains visible in the lower suit contour.
- The figure is still a photographic raster, against the HIG advice to prefer illustrations; detail in the face is lost in Clear/Tinted and at small sizes.
- Rights: the figure closely resembles a well-known film character (see `docs/ICON-RESEARCH.md` section 1, open question 1). Not resolved here.
