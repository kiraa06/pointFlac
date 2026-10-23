# Turntable themes for pointFlac "Customize deck" - research

Date: 2026-10-23. Not legal advice. Items marked [verified] came from fetched/searched sources; [general knowledge] are from background knowledge and should be checked before relying on them.

## 0. Bottom line

- Ship 8 original themes, all drawn procedurally in SwiftUI Canvas/Path from one parameterised "deck model" (plinth, platter, mat, arm, cartridge, controls, lighting). Do not bundle third-party SVGs.
- Treat the archetypes below as design vocabulary (proportions, materials, colour logic), never as outlines to trace. No brand names, logos, or model numbers in UI or code symbols.
- Premium feel comes from layered material rendering (gradients, specular, micro-texture, soft shadows), physically plausible motion (spin-up inertia, arm lowering with damping), and cohesive lighting, more than from the number of themes.

## 1. Archetypes (design vocabulary)

Top-down view is what matters: plinth outline, platter, arm pivot position, control cluster.

1. **1970s Japanese direct-drive DJ deck (SL-1200 spirit)**
   - Rectangular plinth, slightly deeper than wide (approx 453 x 353 mm real world, near 1.28:1), rounded-small corners, four feet. Silver brushed-aluminium top or matte black.
   - Platter: heavy aluminium, with a ring of strobe dots/slots on the edge, a rubber mat with fine concentric grooves, spindle.
   - Right-rear: straight-ish J/S tonearm pivot on a round base with height ring, anti-skate dial, cueing lever, rest clip. Static-balance counterweight at rear.
   - Left of the platter bottom: speed buttons (33/45), start/stop large square button; pitch fader slot at bottom-right with centre detent; small pop-up target light on the rear left; neutral/quartz-lock LED.
   - Palette: silver #C9CCD1 / graphite #2B2D31, red LED #FF3B30, amber lamp #FFB84D, white strobe dots.
   - Source for general spec: [Wikipedia, Technics SL-1200](https://en.wikipedia.org/wiki/Technics_SL-1200) (cast alloy top plate, solid rubber base) [verified].
2. **Danish minimalist linear-tracking deck (Beogram spirit)**
   - Very low, slender, near-rectangular slab, often black or aluminium with a thin edge. No visible tonearm pivot: a tiny tangential carriage rides a straight rail across the record; the arm is short and straight, with a light pointer.
   - Touch/slider controls hidden or flush; one tiny indicator; symmetric, almost no ornament. Rosewood/teak side strips optional.
   - Palette: brushed aluminium #B8BCC2, black #101113, warm wood #8A5A3B accent.
   - Reference: Beogram 4000 designed by Jakob Jensen in 1972 [verified, [The Vinyl Factory](https://www.thevinylfactory.com/features/timeless-beauty-minimal-turntable-design)]. Make the linear arm a motion highlight: slides radially as the track progresses (great fit for a progress indicator).
3. **German 1950s Bauhaus radiogram (SK4 spirit)**
   - White powder-coated sheet-metal U-shaped body between light wood (ash/beech) side cheeks, clear acrylic lid with a thin metal frame, restrained grid-based control strip with small rotary knobs and a sans-serif label band (use an original label style, not that foundry's).
   - Platter in pale grey/white with black felt; slim straight arm.
   - Facts: Developed by Dieter Rams and Hans Gugelot in 1956; acrylic lid adopted after a sheet-metal lid rattled; nicknamed "Snow White's coffin" [verified, [The Vinyl Factory](https://archive.thevinylfactory.com/?p=80404), [Cooper Hewitt](https://www.cooperhewitt.org/?p=10611), [Montecristo Magazine](https://montecristomagazine.com/design/phonosuper-sk4-1956), [Design und Text](https://www.designundtext.com/en/2.1.16_braun-design-sk4-gugelot-rams-pbdd.php)].
   - Palette: off-white #F1EFE8, ash #D8BE95, translucent lid tint rgba(220,235,245,0.25), signal orange #E8590C for a single dot/knob.
   - Dribble idea: acrylic lid as a glassy overlay layer with moving reflection tied to device tilt (CoreMotion), plus subtle dust-free highlights.
4. **British belt-drive audiophile (Rega / Linn spirit)**
   - Rega-like: thin, light rectangular plinth (often a skeleton or foam-core sandwich with glossy laminate, black/white/red gloss), glass or thin platter, small felt mat, a slim fixed-pivot arm with a distinctive angular tube, tiny feet. No visible controls on top; speed via belt on pulley.
   - Linn-like: wooden (walnut/oak/cherry/black ash) box plinth with veneer, aluminium sub-chassis visible beneath, round-ish platter with thick mat, a separate counterweight arm, power switch on the front-left.
   - Heritage: LP12 introduced 1972, suspended sub-chassis, descends from an AR design of 1961 [verified, [Wikipedia, Linn Sondek LP12](https://en.wikipedia.org/wiki/Linn_Sondek_LP12)]; Rega Planet 1975 and Planar 3 in 1977, philosophy "light and rigid" [verified, [Wikipedia, Rega Planar 3](https://en.wikipedia.org/wiki/Rega_Planar_3), [Stereophile](https://stereophile.com/content/gramophone-dreams-14-rega-planar-3)].
   - Palette (wood): walnut #5B3A29, oak #B98E5E, black ash #1B1A19; (gloss): red #B3202A, white #F4F4F2.
5. **High-end mass-loaded acrylic/aluminium deck (Clearaudio / VPI spirit)**
   - Thick, layered slabs (clear or smoked acrylic, black POM, aluminium), visible bolts and spindle clamp, outboard motor pod, massive platter with record clamp or weight, heavy isolation feet (spike/cone), 9-12 inch arm with a decoupled counterweight, often with an arm-mount pillar.
   - Palette: smoked acrylic rgba(30,34,40,0.6), polished aluminium, anodised accents (champagne #C8B48E, black #101214), machined screw heads.
   - Rendering value: refraction/edge-glow on acrylic, bevel highlights, bolt heads - the "intricate" theme.
6. **Swiss/German classics (Thorens / Dual spirit)**
   - Thorens-like: 1960s-70s square-ish plinth with metal top plate, a large aluminium or die-cast platter with strobe markings, idler-wheel or belt, a long S-arm with a lift lever, speed knob.
   - Dual-like: changer/"hi-fi" style, black or walnut base, silver top, chunky selector and speed knobs, a centre-spindle adaptor, record stacking spindle optional.
   - Palette: champagne metal #C9BFA8, black #17181A, walnut #6B4A36, warm cream scale markings #F2E9D8.
7. **Colourful modern entry deck (Pro-Ject / Audio-Technica spirit)**
   - Flat thin MDF plinth in gloss colours (red, blue, green, white, yellow, black), thin glass or acrylic platter, a single carbon-fibre arm in black or red, push button, belt-drive, a clean tonal presence.
   - Palettes: signal red #D7263D, ocean #1E6FA8, mint #78C2AD, mustard #E1AD01, plus a white/black neutral.
8. **Suitcase portable (Crosley spirit)**
   - Leatherette case (green, red, cream, navy), rounded corners, brass/chrome latches and corner caps, a speaker grille cloth with a tiny perforation grid, a small tonearm (ceramic cartridge) and a volume/speed knob, felt platter.
   - Palette: teal leatherette #2F6F6A, cream #E8DFC8, brass #C9A24B, grille fabric #3A2E27.
9. **1930s-50s gramophone / 78 deck**
   - Dark polished wood cabinet, brass tonearm on a swivel with a big soundbox (shellac-era), a crank/knob, an enormous felt-covered platter, optional horn silhouette, speed governor, a brass nameplate (use generic text).
   - Palette: mahogany #4A2417, brass #B8913A, shellac black #0C0A09, aged cream label #E6D6B0.
10. **Futuristic/transparent concept deck**
    - Floating glass/acrylic plinth with edge-lit neon, "invisible" platter ring, thin carbon or glass arm, projected holographic strobe and a light-line display. Frosted glass base (similar to the current pointFlac look), magnetic levitation illusion.
    - Palette: ice #CFE8FF, cyan #00E5FF, magenta #FF2BD6, dark glass rgba(10,16,28,0.55).

## 2. Suggested theme set (original names, no brands)

| # | Name | Archetype | Core palette | Signature detail |
|---|------|-----------|--------------|------------------|
| 1 | Studio Silver | Direct-drive DJ deck | Brushed silver #C9CCD1, graphite #2B2D31, red LED #FF3B30 | Strobe ring, pitch fader with centre detent, pop-up target lamp |
| 2 | Night Shift | Matte-black DJ variant | #121315 plinth, #3A3D42 platter, amber #FFB84D | Dim cue lamp, amber strobe, slim glowing tick marks |
| 3 | Walnut | British wooden box deck | Walnut #5B3A29, aluminium #B8BCC2, felt #1F1F1F | Visible sub-chassis shadow, veneer grain, brass spindle |
| 4 | Bauhaus White | Radiogram | Off-white #F1EFE8, ash #D8BE95, orange #E8590C | Clear lid with reflection, grid of tiny knobs, one orange dot |
| 5 | Midnight Acrylic | Mass-loaded acrylic/aluminium | Smoked acrylic, black POM, champagne anodise | Bolts, outboard motor pod, heavy clamp, refractive edges |
| 6 | Linear | Linear-tracking slab | Aluminium #B8BCC2, black #101113, teak accent | Radial rail arm that slides with playback progress |
| 7 | Studio Colour (alt: "Pop") | Modern entry deck | Choice of red/blue/mint/mustard gloss | Thin plinth, glass platter, carbon arm; user picks colour |
| 8 | Portable | Suitcase | Teal #2F6F6A, cream #E8DFC8, brass #C9A24B | Latches, grille cloth, felt mat |
| 9 | Shellac (optional) | 78 gramophone | Mahogany #4A2417, brass, aged cream | Soundbox arm, crank, speed knob |
| 10 | Glasshouse (optional, current look) | Futuristic/transparent | Ice, cyan #00E5FF, dark glass | Edge-lit plinth, hologram strobe; keep as the legacy default |

Naming rules: no brand words ("Technics", "Beogram", "Rams", "SK4", "Snow White" should not appear), no model numbers, no "Rega-style".

## 3. Customisation dimensions and what exists

### Dimensions users enjoy (ordered by perceived value per effort)
1. **Colourway presets within a theme** (plinth + accent) - cheapest, highest delight.
2. **Plinth material:** matte black, silver brushed, walnut/oak/black-ash veneer, gloss lacquer (colours), acrylic (clear/smoked), leatherette.
3. **Platter finish:** brushed aluminium, anodised black, glass, smoked acrylic, felt, with or without a strobe ring (strobe is a distinct visual pattern).
4. **Slipmat designs:** felt (solid colours), rubber (ridged), cork, patterned (concentric rings, checker, geometric, "album art as mat"), plus a seasonal/limited set. Slipmat with album artwork is the single most "personal" feature - the artwork can be shown through the record label area instead.
5. **Tonearm style and colour:** straight vs S-shaped vs J; finish (chrome, black, brass, carbon weave, red anodised); headshell colour.
6. **Cartridge colour:** coloured body (red, blue, orange, wood) - a small, cheap-feeling detail that delights.
7. **Display/strobe light colour:** green, amber, red, ice-blue, white, RGB; display style (dot-matrix, 7-segment, VFD, none).
8. **Lighting mood:** ambient (day, dusk, studio, night), an LED glow around the plinth, a target lamp, rim lights that respond to loudness.
9. **Record:** black, coloured, splatter, clear, picture disc; label art from the album.
10. **Sound-of-device extras (optional):** subtle motor hum, needle drop sounds - if the app is bit-perfect, keep these off by default.

### Existing apps and references
- iOS vinyl-style players found in search [verified]: **Vinyl Fetish** (premium custom player layout: record/artwork size and position, crackle) [App Store](https://apps.apple.com/app/id1490719457); **Vinyls** (tints, alternate icons, spinning disc AR) [App Store](https://apps.apple.com/us/app/-/id1556054655); **CRPlayer** (record disk colour and mat colour) [App Store](https://apps.apple.com/app/id1642031569); **TurnPlay** (Ramotion, detailed turntable art, older) [Geeky Gadgets](https://www.geeky-gadgets.com/turnplay-ipad-app-offers-users-a-virtual-realistic-record-player-02-01-2013/), [Engadget](https://www.engadget.com/2012-12-24-daily-ipad-app-turnplay-lets-you-play-a-vinyl-record-on-your-ip.html); **Vinyl Tap** [Hypebot](https://www.hypebot.com/vinyl-tap-incredibly-faithful-ipad-record-player-is-probably-only-one-you-need.md).
- Takeaway from CRPlayer's low rating (1.5/5 from only 2 ratings, tiny sample) and others: offering colour pickers alone does not feel premium; fidelity of the base art and behaviour matters.
- Not verified here (no results fetched): Dribbble/Behance turntable concepts, Winamp skins (Winamp Skin Museum at skins.webamp.org is worth browsing), DJ apps (djay, Serato DJ, Traktor), Native Instruments / Pioneer deck views, game skins. Recommend a designer spends an hour browsing these for reference; search terms "turntable UI" on Dribbble/Behance, "Webamp skin museum" and "djay turntable skin".

### What makes premium ones feel premium
- Layered materials: separate layers for base colour, micro-texture (brushed or grain), specular highlight, edge bevel, contact shadow, ambient occlusion. Fake 3D with consistent top-left light.
- Physically plausible motion: platter spin-up/spin-down with inertia, subtle wow/flutter, arm lowers on a damped curve and drifts inward with playback, strobe dots seem to stand still at exact speed (motion-aliasing is the delight).
- Haptics and micro-interactions: haptic click on the speed switch, a detent on the pitch fader, lamp that warms up gradually.
- Light behaviour: LEDs bloom, lid reflection moves with device tilt, specular on platter follows gyro.
- Typography: tiny but crisp, consistent engraved-style labels, tabular numerals.
- Restraint: one accent colour per theme, no cartoon outlines.
- Performance: draw static layers once (rasterise with drawingGroup or cache as images at launch), animate only the platter, arm, and light layers; avoid a full-canvas redraw each frame. Respect Reduce Motion and battery.

## 4. Open-licensed vector and reference resources

| Resource | Licence | Safe for MIT public app? | Notes |
|---|---|---|---|
| SVG Repo, items marked "CC0 / Public Domain" | CC0 1.0 | Yes, per item, after verifying the item page | SVGRepo licensing page says licences vary and some items are CC0; verify per file [verified, [SVG Repo licensing](https://svgrepo.com/page/licensing/)]. A "DJ turntable vinyl" icon from the Music Line pack was reported CC0 by a third-party directory (unverified) [freeicons.co](https://freeicons.co/v/dj-turntable-vinyl-383655/). Turntable listing: [svgrepo.com/vectors/turntable](https://www.svgrepo.com/vectors/turntable/) |
| SVG Repo, default licence items | Site-specific licence: use in commercial projects, no resale as-is, no redistribution like the site | Risky for a public MIT repo: bundling the file in source redistributes it. Avoid | Per SVGRepo page [verified]. Redistributing in a public repo is "redistribution" |
| Openclipart | CC0 1.0 (public domain dedication), but uploads have historically included mistaken claims | Safe in theory; I did not find specific turntable files. Verify per file and keep a record | Search not confirmed here [not verified] |
| Wikimedia Commons technical drawings, patent drawings | Varies per file: PD (age/US government), CC0, CC BY, CC BY-SA | Only PD/CC0 files; avoid CC BY-SA (share-alike copyleft contaminates assets, though not necessarily code) and CC BY (needs attribution; ok but awkward) | Always read the file's licence box; no Commons turntable file confirmed in search |
| Old US patents (Google Patents) | Public domain in US for the document text and drawings (generally; for patents the document itself is PD, though the claimed design may still be protected while in force) | Reference only (study mechanics: tonearm geometry), e.g. [US2529676A](https://patents.google.com/patent/US2529676A/en) tone arm, [US2363655A](https://patents.google.com/patent/US2363655A/en), [US2628845A](https://patents.google.com/patent/US2628845A), [US1888652A](https://patents.google.com/patent/US1888652A/en), [US4303999A](https://patents.google.com/patent/US4303999) | Expired patents' drawings may be reused; do not trace as-is and keep the geometry as inspiration. Verify the date/expiry; a patent document being public domain does not make its modern product shape free |
| Stock marketplaces (Adobe Stock, Icons8, GetIllustrations, etc.) | Paid/restricted | No | Not compatible with an MIT repo |

Recommendation: **draw procedurally.** Reasons: (1) licensing risk-free, (2) one geometry model drives all themes, so intricate details (grooves, strobe dots, screws, grain) are parametric and resolution-independent, (3) colour/material changes are just parameters, (4) animations (rotating platter, sliding arm) need separate layers anyway, (5) avoids binary asset bloat and keeps the repo MIT-clean. Use public references only to study proportions and mechanics; add a short "no external art" note to the repo's LICENSE/NOTICE.
- Tonearm geometry reference: Baerwald/Löfgren alignment is public maths (effective length, overhang, offset angle) and can drive an accurate arm sweep [general knowledge].
- Real dimensions to scale from (general knowledge, check): record 12 in (305 mm), platter ~ 12-13 in, spindle 7.2 mm, typical pivot-to-spindle distance 222 mm for a 9 in arm, 33 1/3 / 45 / 78 rpm, strobe ring for 50/60 Hz mains.

## 5. Legal cautions (not legal advice; get counsel before launch)

I searched for a specific case on the SL-1200 or Beogram shape and found none [verified: no reports surfaced]. That absence is not clearance.

- **Trade dress (US) / unregistered and registered designs (EU/UK/India):** product shape can be protected as trade dress if it is distinctive (secondary meaning) and non-functional; design patents/registered designs protect ornamental appearance for a fixed term (US 15 years from grant; EU registered design up to 25 years; unregistered EU design 3 years) [general knowledge]. Older icons (1950s-70s designs) may have expired design rights but trade dress/shape trademarks can persist indefinitely if still used as a brand. The SL-1200's and Beogram's silhouettes are widely recognised, so a close replica is the highest-risk path. Functionality doctrine helps for purely functional elements (a platter, a tonearm), not for distinctive aesthetic combinations.
- **Logos and wordmarks:** never reproduce brand names, logos, typefaces designed as logos, or model numbers (including "1200", "SK4", "LP12", "Planar", "Beogram"). Do not use trademarks in App Store keywords, descriptions, or screenshots. Generic labels like "33", "45", "PITCH", "START/STOP" are fine.
- **Nominative/descriptive use:** describing an archetype in internal docs is fine; in marketing, avoid "SL-1200-style" claims. Use "classic direct-drive DJ look" at most, or avoid referencing brands altogether.
- **Staying "inspired by":**
  - Change the overall silhouette (different corner radius, feature placement, control layout, proportions) and combine features from several archetypes.
  - Do not trace photos or CAD; build from primitives and from functional constants (record size, arm geometry).
  - Invent original control labels, icons, and colours; avoid the signature colour-and-layout combos of any one maker (e.g. a red-and-silver pitch fader in the same location and size).
  - Keep a short provenance log per theme (sketch, references, decision notes) as evidence of independent creation.
  - Run a similarity pass: put each theme next to the nearest real product photo, and change anything that would be confused at a glance.
  - Apple App Review also rejects apps using third-party trademarks in UI/metadata; original art avoids that risk.
- **Fonts and sounds:** use system fonts or OFL fonts; no sampled real-deck sounds unless self-recorded.
- **Third-party assets:** if any CC0/PD asset is ever bundled, record the URL, licence text, retrieval date, and author in a THIRD_PARTY_NOTICES file.

## 6. Suggested implementation shape (for the design/plan step)

- `DeckTheme` struct: plinth (shape, material, colours), platter (finish, strobe on/off), mat (pattern, colour), arm (style: S, straight, J, linear, gramophone; finish), cartridge colour, display (style, colour), lighting (mood), controls layout. Themes are static data; user overrides (colourway, mat, cartridge, display colour) stored in UserDefaults.
- Layer model: static base layer (cached), platter (rotating), strobe overlay, arm (rotating about pivot or sliding), light layer (blend modes, bloom), lid/glass overlay.
- Verify with snapshot tests per theme and on small iPhone sizes; maintain 60 fps with the platter only.

## Sources
- https://en.wikipedia.org/wiki/Technics_SL-1200
- https://archive.thevinylfactory.com/?p=80404
- https://www.thevinylfactory.com/features/timeless-beauty-minimal-turntable-design
- https://www.cooperhewitt.org/?p=10611
- https://montecristomagazine.com/design/phonosuper-sk4-1956
- https://www.designundtext.com/en/2.1.16_braun-design-sk4-gugelot-rams-pbdd.php
- https://en.wikipedia.org/wiki/Linn_Sondek_LP12
- https://en.wikipedia.org/wiki/Rega_Planar_3
- https://stereophile.com/content/gramophone-dreams-14-rega-planar-3
- https://svgrepo.com/page/licensing/
- https://www.svgrepo.com/vectors/turntable/
- https://freeicons.co/v/dj-turntable-vinyl-383655/
- https://apps.apple.com/app/id1490719457 , https://apps.apple.com/us/app/-/id1556054655 , https://apps.apple.com/app/id1642031569
- https://www.geeky-gadgets.com/turnplay-ipad-app-offers-users-a-virtual-realistic-record-player-02-01-2013/
- https://patents.google.com/patent/US2529676A/en (and the other patents listed in section 4)

Gaps: Dribbble/Behance, Winamp skins, DJ-app skins, Openclipart and Wikimedia Commons turntable files and exact licence texts were not directly verified (searches returned nothing relevant). Legal figures marked [general knowledge] should be checked with counsel.
