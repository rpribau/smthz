# smthz app icon: Liquid Glass research (Icon Composer)

Research only. No product code, no edits outside `docs/`. `icon/icon.png` and `reference/` were read, never modified.
Date: 2026-10-25. Local toolchain: Xcode 27.1 (build 27A9275), `ictool` and `actool` from `/Applications/Xcode.app`.

Tags: `[verified: source]` = read in an Apple page, a local tool output or a test run here. `[inferred]` = my reasoning or a secondary/forum source that Apple does not document. Forum and search-snippet material is marked as such.

---

## 1. Reference artwork: `icon/icon.png`

Measured with `sips -g`: **1254 x 1254 px, PNG, no alpha channel (`hasAlpha: no`)**. `[verified: source]`

What is in the image (viewed with Read):
- **Outer shape:** a rounded-square "glass tile" with a bright specular rim, a diagonal light streak across the top-left, and a darker lower-right. The four corners are rounded and the area outside the tile is **solid black**, because there is no alpha. `[verified: source]`
- **Background inside the tile:** near-black to dark grey, slightly lighter at the top-left. `[verified: source]`
- **Centrepiece:** a grey-scale, photographic-looking bust of a man in a dark suit, white shirt and dark tie, with sunglasses and a coiled earpiece wire. The head is cut off at the bottom by the tile edge. `[verified: source]`
- **Secondary graphics:** two thin, pale, semi-transparent arcs curving around the head (one on each side) and short vertical dash "bars" in pairs on each side. They are the only non-figure elements. `[verified: source]`
- **Palette:** monochrome (black, greys, white). No hue. `[verified: source]`

Implications for smthz (what to change in the design, not in `icon/`):
1. **The glass tile is baked into the artwork** (rounded corners, rim highlight, gloss, black matte outside). Apple says the system must apply the mask and the glass, and that pre-defined masking "negatively impacts specular highlight effects and makes edges look jagged". `[verified: source]` The baked tile must not be reused as the layer. Only the **content** (figure, arcs, dashes) should be carried over; the tile is replaced by the Icon Composer background and the system's Liquid Glass.
2. **The figure is one flattened raster.** There are no separate layers in `icon/icon.png`. Separating it into a background and foreground layers requires masking or redrawing in a design tool. This is the main production cost. `[inferred]`
3. **Photographic detail.** Apple advises illustrations over photos and warns that "photos are full of details that don't work well when displayed in different appearances, viewed at small sizes, or split into layers". `[verified: source]` The face and suit shading will be the hardest part to make read at 16–32 px and in Clear/Tinted. `[inferred]`
4. **Rights check (open question).** The figure closely resembles a well-known film character. Apple's HIG has no explicit rule for this, but the owner should confirm they have the right to use this artwork before it ships. `[inferred]`

The existing packaging (`scripts/package-app.sh`) makes the `.icns` straight from `icon/icon.png` with `sips`/`iconutil`. That means the black matte and baked tile currently go into the shipped fallback icon. `[verified: source]` See section 9.

---

## 2. Canvas, grid and masking

- Layout size for iOS, iPadOS and macOS: **1024 x 1024 px**, square. The system applies the rounded-rectangle mask. `[verified: source]` (HIG "App icons", Specifications table)
- Provide **square, unmasked** layers. "The system masks all layer edges to produce an icon's final shape. For iOS, iPadOS, and macOS icons, provide square layers so the system can apply rounded corners." `[verified: source]`
- Do **not** bake rounded corners, drop shadows, bevels, glows, blurs or gloss. "There's no need to include specular highlights, drop shadows between layers, beveled edges, blurs, glows, and other effects." `[verified: source]`
- Keep primary content centred so the mask and corner adjustments do not truncate it. Apple's grid templates are in Apple Design Resources (not fetched). `[verified: source]`
- Colour spaces: sRGB, Gray Gamma 2.2 (greyscale) or Display P3 (macOS supported). The reference is greyscale, so use Gray Gamma 2.2 or sRGB. `[verified: source]`
- Safe area: no numeric value in the HIG for macOS. Use the template grid (not fetched) and the "keep content centred" rule above. The third-party "central 70 %" figure from search snippets was not verified against Apple. `[inferred]`
- Canvas **1024 px** is the master; the reference at 1254 px is larger than needed. Downscale from a 1024 master, do not resample 1254 by hand. `[inferred]`

## 3. Layer model

- A macOS icon has **one background layer and one or more foreground layers**. "iOS, iPadOS, macOS, and watchOS app icons include a background layer and one or more foreground layers." `[verified: source]`
- Icon Composer supports the background as a **solid colour or gradient**; an imported background image must be full-bleed and opaque. "Icon Composer supports solid colors and gradients for background layers, making it unnecessary to import custom background images in most cases." `[verified: source]`
- Foreground layers: prefer **clearly defined edges**; avoid soft or feathered edges, because the system's highlights and shadows need hard edges. `[verified: source]`
- **Vary opacity** in foreground layers for depth; import opaque layers and adjust transparency in Icon Composer. `[verified: source]`
- **Groups** let you apply Liquid Glass properties (specular, refraction, translucency) to several layers at once. `[verified: source]`
- Practical layer plan for smthz (inferred from the reference):
  1. **Background:** solid near-black / dark charcoal gradient (full-bleed, 1024 px, no tile).
  2. **Group "figure":** the bust as a transparent PNG (or vector) with the suit, shirt, tie, head, sunglasses; sub-layers for shirt/tie and head so the glass can separate them.
  3. **Group "rings":** the two arcs, one layer each, at reduced opacity so they read as glass.
  4. **Group "dashes":** the dash bars, opacity-varied.
  5. The earpiece wire is a thin element: probably drop it at 16–32 px `[inferred]`.
- Keep the total number of layers low (3–5 groups). Apple's guidance is "simplicity" and "a minimal number of shapes". `[verified: source]`

## 4. Liquid Glass properties (Icon Composer)

Apple's Icon Composer page lists these adjustable properties: **specular highlights, refraction, translucency, and shadows**. `[verified: source]`
- **Specular highlights:** "Crisp, specular highlights elevate and define each layer." You can choose inside/outside alignment, or let Icon Composer decide from the layer colour. `[verified: source]`
- **Refraction:** "By bending light through your icon, Refraction lets layers pick up and transmit color and shape from what's behind them." Strength is set per layer. `[verified: source]`
- **Translucency and shadow:** per layer / group. `[verified: source]`
- **Per-layer glass on/off:** the `glass` flag per layer in `icon.json` (see section 7). The presence of the flag in the probe confirms it is per layer. `[verified: local test — probe `icon.json` uses `"glass": true`, actool accepted it]`
- Blur material: Apple's HIG says the system applies blur; do not paint blur in the artwork. `[verified: source]`
- The system generates the dark, clear and tinted variants when you do not supply them. `[verified: source]`

Caveat: the exact Liquid Glass value ranges and the UI for "clear" are only visible in the GUI. `[inferred]`

## 5. Appearances

macOS can show an icon as **Default, Dark, Clear (light/dark) and Tinted (light/dark)**. The HIG lists six variants for iOS, iPadOS and macOS. `[verified: source]`

The probe (section 8) exported these renditions from `ictool`: `Default`, `Dark`, `ClearLight`, `ClearDark`, `TintedLight`, `TintedDark`, `Mono`. `[verified: local test]`
The compiled `Assets.car` contained `NSAppearanceNameAqua` (light), `NSAppearanceNameDarkAqua` (dark) and `ISAppearanceTintable` (tint) appearance keys. `[verified: local test]` Note: the search summary said Icon Composer has "Default, Dark, Mono"; the Icon Composer page says the same (Default, Dark, Mono; Clear and Tinted not mentioned). `[verified: source]` The local tool exposes all six renditions, so the HIG list is the authority. `[inferred]`

How to design each (HIG guidance, applied to smthz):
- **Default:** the full-colour (here: greyscale) design. This is the master. `[verified: source]`
- **Dark:** "Use your light app icon as the basis for your dark icon." Keep core features identical; use a background that contrasts. "Color backgrounds generally offer the greatest contrast in dark icons." `[verified: source]` For smthz the Default is already dark, so Dark should be a slightly lighter or cooler background plus brighter figure edges, so the figure does not sink into the background. `[inferred]`
- **Clear (light/dark):** the glass is more transparent; avoid large dark masses behind thin elements. `[inferred]`
- **Tinted (light/dark):** the system tints the layers. Keep the figure as the high-contrast shape; avoid relying on hue. The `ictool` `--tint-color` and `--tint-strength` flags exist for previewing. `[verified: local tool help]`
- **Mono:** single-colour rendering. Keep the silhouette legible in one hue. `[verified: source (Icon Composer page: Mono)]`
- Keep features consistent across appearances; "avoid creating custom icon variants that swap elements in and out". `[verified: source]`

## 6. Colour, contrast and legibility

- Greyscale is valid (Gray Gamma 2.2 is a listed colour space). `[verified: source]`
- Contrast: "A great app icon is visible, legible, and recognizable, regardless of its appearance variant." `[verified: source]`
- Avoid excessively bright images in Dark. `[verified: source]`
- Avoid thin lines and sharp corners; they lose detail at small sizes. `[verified: source]`
- Avoid black as the background in watchOS (not macOS, but relevant if the icon is reused). `[verified: source]`
- No text (HIG: include text only when essential). The reference has none. `[verified: source]`
- Check at 16, 32 and 64 px, Light and Dark menu bars, Dock, Finder and Spotlight. `[inferred]`

## 7. Vector vs raster layer assets; the `.icon` file

- Apple: "Prefer vector graphics when bringing layers into Icon Composer… Outline artwork and convert text to outline… For mesh gradients and raster artwork, prefer PNG format because it's a lossless image format." `[verified: source]`
- So: vector (SVG/PDF) for the arcs and dashes; **transparent PNG** for the photographic figure (or vector if it is redrawn). Use 1024 px PNGs with alpha. `[verified: source (HIG) + inferred for sizes]`
- `.icon` file: a **folder package** with `icon.json` plus an `Assets/` folder with the layer images. The probe confirmed this structure: `Probe.icon/icon.json` and `Probe.icon/Assets/ref.png`. `[verified: local test]` Apple's pages do not document the internal schema. Keys seen in the probe: `color-space-for-untagged-svg-colors`, `fill`, `groups[].layers[]` (`image-name`, `name`, `glass`, `position` with `scale`, `translation-in-points`), `groups[].shadow`, `groups[].translucency`, `supported-platforms`. `[verified: local test — accepted by actool; the full schema is inferred]`
- Store the `.icon` in the repo as an authored source (e.g. `design/smthz.icon`), **not** in `icon/` (which is read-only for this project). `[inferred]`
- Export: Icon Composer can export a flattened image for marketing. `[verified: source]` Use `ictool` (section 8) to export renditions for review. `[verified: local test]`

## 8. Build integration without an Xcode project (SwiftPM .app)

Verified on this machine with an actool compile of a probe `.icon` (scratchpad, not the project):

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ACTOOL="$DEVELOPER_DIR/usr/bin/actool"
"$ACTOOL" build/design/smthz.icon --compile build/icon-out \
  --output-format human-readable-text --notices --warnings --errors \
  --output-partial-info-plist build/icon-out/partial.plist \
  --app-icon smthz --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 26.0
```

Result (probe): exit 0, produced `Assets.car` (~3.6 MB, with the Aqua/DarkAqua/Tintable appearances), `Probe.icns` (~94 KB, legacy fallback) and `partial.plist` with:
```xml
<key>CFBundleIconFile</key><string>Probe</string>
<key>CFBundleIconName</key><string>Probe</string>
```
`[verified: local test]`

Integration steps for `scripts/package-app.sh` (proposal, not implemented):
1. Run `actool` as above into a temp dir.
2. Copy `Assets.car` to `Contents/Resources/`.
3. Copy the generated `smthz.icns` to `Contents/Resources/` (fallback for older systems; keep the name `smthz.icns`).
4. Merge the partial plist keys into `Info.plist`: `CFBundleIconName` = `smthz` and keep `CFBundleIconFile` = `smthz`.
5. `codesign` as now.

Why both keys: Apple's Liquid Glass lookup uses `CFBundleIconName` with `Assets.car`; the `.icns` via `CFBundleIconFile` is the fallback. `[inferred from the forum thread and the probe output; not in Apple docs]`

Caveats (from the Apple Developer Forums thread 794485, fetched via a summarising tool, secondary):
- `--enable-icon-stack-fallback-generation=disabled` (an undocumented `ASSETCATALOG_OTHER_FLAGS` flag) was reported to suppress legacy size generation on Xcode 26.0 and to be ignored on 26.1. `[verified: forum; undocumented; do not rely on it]`
- Apple's Icon Composer page says the feature **requires macOS Tahoe 26.4 or later**. Our `LSMinimumSystemVersion` is **26.0**. This conflicts or needs clarification. `[verified: source]` Open question.
- Icons from a `.icon` file are not loadable by name at runtime; bundle a separate image asset if the app needs its icon in the UI. `[verified: forum; secondary]`
- The `.icns` fallback is generated from the same artwork; if it looks wrong on Sequoia and earlier, a separate fallback `.icns` is needed. `[inferred]`

## 9. Verification

1. **ictool renditions** (the exact flags from `ictool` usage):
   ```sh
   ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
   for r in Default Dark ClearLight ClearDark TintedLight TintedDark Mono; do
     "$ICTOOL" design/smthz.icon --export-image --output-file "build/preview-$r.png" \
       --platform macOS --rendition "$r" --width 1024 --height 1024 --scale 1
   done
   ```
   Verified this exact invocation works for all seven renditions on the probe. `[verified: local test]`
2. **actool output:** check `Assets.car` with `assetutil --info` (Appearances keys) and the `partial.plist` keys. `[verified: local test]`
3. **Icon Composer preview** in the GUI (manual).
4. **Finder / Dock / Spotlight screenshots** of `build/smthz.app` at 16, 32, 128, 512 px in Light and Dark menu bar modes (manual; the designer or user). `[inferred]`
5. **Check bundle:** `plutil -p Contents/Info.plist` shows `CFBundleIconName`; `codesign --verify` passes.

## 10. Step-by-step checklist (for the designer)

1. Confirm rights to the figure (section 1, item 4). Stop and ask the user if unclear.
2. Create a 1024 x 1024 master canvas, square, no mask, no shadows, no gloss.
3. Background: solid or gradient (dark charcoal), full-bleed.
4. Separate the figure into layers: the figure, the two arcs, the dash bars. Export **transparent PNG at 1024** (or vector where redrawn). Use hard edges. Drop the wire at small sizes if it fails the 32 px test.
5. Group the figure and the rings/dashes; apply glass per group; keep opacity variation.
6. In Icon Composer, add the background and the layers. Set specular and refraction per group. Keep layer count low (3–5).
7. Annotate Default, Dark, Clear, Tinted (Mono) per the rules in section 5; keep the core features the same.
8. Save as `design/smthz.icon` (not `icon/`).
9. Export renditions with `ictool` and review each at 16, 32, 128, 512 px.
10. Compile with `actool` (section 8); check `Assets.car` and the partial plist.
11. Update `scripts/package-app.sh` (proposal in section 8) to ship `Assets.car` + `.icns` + `CFBundleIconName`. Do this only after the user accepts the change.
12. Run `open build/smthz.app` and take Finder/Dock screenshots; attach them to the review.

## 11. Verified vs inferred

**Verified (source or local test):**
- Reference: 1254 px, no alpha, baked tile, black matte, greyscale, figure + arcs + dashes (direct inspection).
- HIG: 1024 px canvas, square layers, no baked effects/masks, layers (background + one or more foreground), vector preferred, PNG for raster, colour spaces, appearances, "simplicity", illustrations over photos, consistency across appearances.
- Icon Composer page: properties (specular, refraction, translucency, shadows), Default/Dark/Mono, flattened export, `.icon` integrates with Xcode, requires macOS Tahoe 26.4 or later.
- Local: `ictool` help and usage (all seven renditions exported); `actool` compile of a probe `.icon` (exit 0; `Assets.car`, `.icns`, `CFBundleIconName`/`CFBundleIconFile`); Xcode 27.1 is the active toolchain for these tools (not `xcode-select`).
- Forum (secondary): `--enable-icon-stack-fallback-generation=disabled` behaviour varies by Xcode version; the Icon Composer `.icns` fallback behaviour on Sequoia.

**Inferred (not in Apple docs or not tested):**
- The layer split for the reference and its visual result.
- The exact `icon.json` schema (only the keys the probe needed are known).
- Whether `CFBundleIconName` alone is enough on older macOS (the `.icns` fallback is assumed to be needed).
- Safe-area numbers (the "70 %" figure is an unverified third-party claim).
- That Dark/Clear/Tinted will look right without visual review.

**Not done:**
- I did not visually inspect the probe renditions (`r-*.png` in the scratchpad) beyond confirming they exist and exit 0.
- I did not fetch the WWDC25 session transcripts (search summaries only).
- I did not fetch Apple Design Resources (grid templates).
- I did not open Icon Composer's GUI.

## 12. Open questions

1. **Rights** to the figure (resembles a known film character). Owner to confirm.
2. **Minimum OS:** Icon Composer page says Tahoe 26.4+, our `LSMinimumSystemVersion` is 26.0. Which should the app use?
3. **Layer production:** redraw the figure as vector (cleaner, more work) or mask the raster (faster, weaker at small sizes)?
4. **`.icns` fallback:** ship the generated fallback, or drop it if the app is Tahoe-only?
5. **Xcode version:** the probe used Xcode 27.1; should the build pin a toolchain, and is the `--design-generation` (26 vs 27) flag relevant to what we ship?
6. **Package change:** approve the `scripts/package-app.sh` change (section 8) before implementation; it changes what the shipped bundle contains.

## Sources

- Apple HIG, App icons (fetched in Markdown): https://developer.apple.com/design/human-interface-guidelines/app-icons.md
- Apple, Icon Composer (fetched, summary): https://developer.apple.com/icon-composer/
- Apple Developer Forums, Icon Composer and `.icns` fallback (fetched via summary, secondary): https://developer.apple.com/forums/thread/794485
- WWDC25 session 361, "Create icons with Icon Composer" (search summary only; not fetched): https://developer.apple.com/videos/play/wwdc2025/361
- Local: `ictool` usage output; `actool` compile of a probe `.icon` (scratchpad, Xcode 27.1); `icon/icon.png` (read-only); `scripts/package-app.sh`.

## Honest report

- Completed the research with primary sources fetched for the HIG and Icon Composer pages, and a local compile/export probe showing the `.icon` → `Assets.car` → `CFBundleIconName` path works on this machine.
- Caveats: the forum material is secondary, the WWDC transcript and Apple's grid templates were not fetched, and the probe `.icon` is a minimal hand-written file (its schema is inferred). The probe renditions were generated but not visually reviewed.
- The probe lives in the scratchpad (`/private/tmp/claude-501/-Users-robs-Documents-proyectos-smthz/8434562b-1855-4aa0-a853-a9cd327c1a22/scratchpad/icexp`), not in the project. No files in `icon/`, `reference/` or the code were changed.
- `scripts/package-app.sh` was read only; the proposed change is not implemented.
