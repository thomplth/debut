# KHA-422 Liquid Glass comparison lab

This lab compares supported and research-only ways to reproduce the native macOS
Command-Tab surface. It is deliberately separate from Debut's production overlay;
KHA-422 does not change the production default.

## Run the lab

Build one signed app and zip archive for every recipe:

```bash
./scripts/build-glass-lab.sh
```

Run the complete comparison in the headless Tart VM:

```bash
./scripts/tart-glass-lab.sh
```

The VM harness captures its framebuffer instead of using `screencapture`, so it
does not require Screen Recording permission. It captures the native Command-Tab
surface and every lab recipe in light and dark appearance for these states:

- normal
- Reduce Transparency
- Increase Contrast
- Reduce Transparency and Increase Contrast together

That produces and validates 104 images under
`~/Library/Caches/Debut/TartE2E/glass-lab/results`. Validation rejects missing or
uniform-luminance images, which catches the silent blank-capture failure mode.

## Build matrix

Every row is a separately launchable `.app` and `.app.zip` under
`.build/glass-lab-builds`.

| Artifact suffix | Implementation | API status |
| --- | --- | --- |
| `swiftui-independent-clear` | Independent SwiftUI `.glassEffect(.clear)` plates | Supported |
| `swiftui-independent-regular` | Independent SwiftUI `.glassEffect(.regular)` plates | Supported |
| `swiftui-container-clear` | Clear plates inside `GlassEffectContainer(spacing: 0)` | Supported |
| `swiftui-container-regular` | Regular plates inside `GlassEffectContainer(spacing: 0)` | Supported |
| `appkit-clear` | Embedded content in `NSGlassEffectView`, clear style | Supported |
| `appkit-regular` | Embedded content in `NSGlassEffectView`, regular style | Supported |
| `appkit-tuned-neutral` | Embedded regular AppKit glass with neutral tuning | Supported |
| `legacy-hud` | `NSVisualEffectView.Material.hudWindow` | Supported legacy control |
| `legacy-popover` | `NSVisualEffectView.Material.popover` | Supported legacy control |
| `swiftui-thick-material` | SwiftUI `.thickMaterial` | Supported legacy control |
| `private-dock` | `NSGlassEffectView.Style(rawValue: 2)` | Research only; private |
| `private-app-icons` | `NSGlassEffectView.Style(rawValue: 3)` | Research only; private |

All variants use identical geometry, content, icon selection, spacing, and
background applications. The recipe label is the only intentional content
difference. Research builds display `RESEARCH ONLY` in the UI.

## Findings

The supported AppKit path gives the most useful control and the closest supported
result. Each plate must be an `NSGlassEffectView`, and its `NSHostingView` must be
assigned as the glass view's actual `contentView`. The glass views belong inside
one `NSGlassEffectContainerView(spacing: 0)`.

The tuned neutral recipe uses:

- regular glass style
- 28 pt continuous corner radius
- neutral 50% white tint at 10% opacity
- 0.5 pt white border at 18% opacity
- black shadow at 28% opacity, radius 22, vertical offset -8

It preserves text and selection legibility in all four accessibility states.
Public regular glass responds appropriately to Reduce Transparency and Increase
Contrast. The legacy HUD, popover, and thick-material variants do not reproduce
the native lensing or accessibility response closely enough.

`GlassEffectContainer` changes grouping behavior but does not by itself make
three separate plates resemble the native surface. The largest remaining visual
difference is hierarchy and geometry: native Command-Tab uses one large unified
platter, while Debut's comparison intentionally retains three plates.

### Private style result

Raw style 3 (`appIcons`) is **not** the missing match. It changes density and
lensing relative to public regular glass, but remains three independent surfaces
and does not reproduce the native unified platter. Raw style 2 has the same basic
limitation. Both raw values are undocumented implementation details and must not
ship, regardless of visual result.

### Interaction and performance

The static selected state remains legible in every supported recipe. The targeted
VNC pass visibly delivered hover changes. VNC click and synthetic drag input did
not mutate the SwiftUI selection or plate position; this is consistent with the
synthetic-drag limitation documented for the project's VM E2E suite. The images
remain under the capture root's `interactions` directory, and are not presented
as proof of click or drag delivery.

The complete matrix repeatedly launched and dismissed all 12 builds without a
hang or crash. This is a smoke/perceived-performance check, not a production
benchmark. The comparison app owns one hosting view per plate and has no polling
or timers.

## Recommendation

Use the `appkit-tuned-neutral` hierarchy and values as the supported starting
point for a future production prototype. Do not use either private raw style. A
production change should first decide whether Debut should adopt the native
single-platter hierarchy; then add production screenshot and interaction tests
before changing the default. KHA-422 intentionally stops at the isolated lab and
leaves the current Debut overlay unchanged.
