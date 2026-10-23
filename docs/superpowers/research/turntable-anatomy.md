# Turntable anatomy, motion and 2D rendering reference

Purpose: let a designer draw a top-down turntable accurately in SwiftUI.
Confidence tags: [V] verified by a source fetched in this session; [D] derived by arithmetic (shown); [K] industry-standard knowledge, not re-verified in this session (check before treating as exact).
All sizes in mm unless stated. R = 12" record = 302 mm (11.89" real pressing ~ 302 mm).

## Sources
- S1 Technics SL-1200MK2 service manual: https://steampoweredradio.com/pdf/technics/manuals/Technics%20SL-1200MK2%20Service%20Manual.pdf
- S2 RIAA bulletins E1/E4 (1978 LP dimensional standards): https://www.bostonaudiosociety.org/pdf/RIAA%20Bulletins%20E1%20&%20E4_1978%20LP%20dimensional%20standards.pdf
- S3 Alignment geometry discussion (Baerwald/Stevenson numbers): https://www.whatsbestforum.com/threads/baerwald-lofgrenb-stevenson-the-math-behind-alignment-conventions.37508/post-909686
- S4 Phaedrus protractor page (arm length ranges): https://phaedrus-audio.com/protractor.htm
- S5 Pro-Ject AlignIt guide: https://www.project-audio.com/wp-content/uploads/2018/07/PJ-AlignitS-Userguide-120825.pdf
- S6 Stereonet alignment thread: https://www.stereonet.com/forums/topic/301904-so-which-cartridge-alignment-method-do-you-use-baerwald-loefgren-or-stevenson/

## 1. Anatomy, top view

### Record (the reference object)
- 12" LP: 302 mm outer diameter [K]. Centre hole ~7.26 mm (0.286") [V S2-derived search]; spindle 9/32" = 7.14 mm [V forum].
- Outermost recording groove ~297.6 mm dia (11.719") and minimum recording diameter ~120.6 mm (4.750") per RIAA E1 [V, table scan garbled; verify in S2]. So: lead-in spiral begins about 2-3 mm inside the edge; music grooves span radius ~148.8 mm down to ~60.3 mm.
- Label: typically ~100 mm dia (radius ~50) [K]. Run-out/dead wax: the band between the last music groove (~r 60) and the label (~r 50), roughly 10 mm wide, a fast "locked groove" or concentric spiral-out ending at the label edge [K].
- Lead-in: ~2-3 mm of widely spaced, silent spiral at the outer edge; track gaps between songs are visible as slightly smoother (darker, less diffuse) rings [K].
- 45 rpm 7": 175 mm, large 38 mm hole (use an adapter) [K]. Thickness ~1.5-2 mm; slight raised rim and raised label area so the groove area never touches the mat [K].
- Visual: black PVC, groove density gives fine concentric rings; reads as dark grey with an anisotropic light band (see section 3).

### Plinth
- Technics SL-1200MK2: 453 x 162 (H) x 360 (D) mm [V S1; the common "353" depth is wrong, service manual/dealers say 360]. Platter 332 mm [V S1, 33.2 cm].
- Typical consumer decks: 420-450 W x 330-370 D. Use ratio W:D about 1.25:1 (453/360 = 1.26). Rounded-rectangle, corner radius ~8-15 mm, plus a visible chamfer/bevel line ~3 mm.
- Materials: matte black ABS/ painted MDF/ die-cast aluminium (Technics, steel-grey/black with fine stipple); wood-veneer with grain (walnut, oak); gloss piano black. Top surface often has a subtle texture (stipple) and slightly lighter bevelled edge.
- Layout on top: platter centre sits about 40-45 % from the left, 50-55 % down from the top for a right-handed layout; tonearm base in the right-rear corner; controls in the front-left/front strip; pitch fader on the right-front (Technics) running front-back.

### Platter
- Diameter: 332 mm (SL-1200) [V S1]; typical 295-335. Rule: platter should be slightly larger than or about equal to the record, record visibly overhangs only on cheap decks [K]. A 300 mm platter just under the record is plausible on budget belt decks, but a platter clearly smaller than a 302 mm record looks wrong on a DJ deck. Draw 332 (1.10 R) for DJ, ~300 (≈0.99 R) for hi-fi.
- Rim profile: seen from above a thin lighter outer ring (~1.5-3 mm top bevel), then a recessed ledge where the mat sits. Strobe band is machined on the outer vertical-ish edge of the SL-1200 and reads as a ring of ~8 mm at the extreme rim [K].
- Strobe dots (the pattern is mains-frequency based). Neon/mains lamp flashes at 2 x line frequency, so dots per revolution N = 2 f x 60 / rpm [D]:
  - 50 Hz, 33⅓ rpm: 100 x 60 / 33.333 = 180 dots [D]
  - 50 Hz, 45 rpm: 6000 / 45 = 133.3, drawn as 133 [D]
  - 60 Hz, 33⅓ rpm: 7200 / 33.333 = 216 dots [D]
  - 60 Hz, 45 rpm: 7200 / 45 = 160 dots [D]
  - SL-1200-style platter has 4 rows, innermost to outermost 50/33, 50/45, 60/33, 60/45 is the usual convention [K]. Dots are small rectangular bars with equal black/white pitch; each row has a different count (180, 133, 216, 160 gives bars of width 360/N degrees/2).
  - Quartz-lock Technics also has the platter-edge pitch markings: +6 %, +3.3 %, 0, -3.3 % [V search summary of SL-1200 sources]. Do not confuse with the dots.
- Typical finish: die-cast aluminium, satin/ brushed on rim, dark underneath. Weight 2 kg (MK2) [V]. Platter casting has an inner recessed ring.

### Mat / slipmat
- Rubber (Technics: ~3-5 mm, textured grooves concentric, black), felt (DJ slipmat, 1-2 mm, printed logo, sits slightly smaller than record, ~300 mm), cork (~3 mm, tan with speckle), acrylic/glass (clear, 3-12 mm, thick edge catching light). Typical diameter 290-300 mm (slightly smaller than record) so the record rim overhangs [K].
- Rubber mat: concentric ribs, fine matte; felt: soft fibres, matte, slightly lighter than record.

### Spindle
- ~7.14 mm (9/32") shaft [V], with a tapered domed tip protruding ~6-8 mm [K]. Top-down: a small bright chrome circle, radius 3.5 mm, with an offset specular dot and a tight dark ring shadow. Record label hole around it is 7.26 mm.
- Some automatic decks have a spindle with a ratchet/ changer arm collar; draw only the plain case.

### Record clamp / weight
- Screw-on stabiliser (e.g. ~ 40-60 mm dia, 200-300 g) or a flat puck clamp that sits on the label: usually 38-60 mm dia, brass/aluminium, with a knurled outer ring and a central collar. Draw as a circle on the label with a concentric ring, brushed highlight and soft drop shadow.

### Tonearm families
- S-shaped: S-curved tube that places the headshell at the offset angle without a cranked headshell (Technics, Rega is straight-ish). Most popular on DJ decks.
- J-shaped: straight pivot section with a sharp curve at the cartridge end (older Japanese decks).
- Straight: straight tube with a cranked headshell (Rega RB-series, SME 3009 is straight with offset headshell, many hi-fi).
- Tangential/linear-tracking: carriage rides a rail and keeps the cartridge tangent to the groove (Revox, Bang & Olufsen Beogram, Rabco); zero tracking error, tiny offset, arm moves in a straight line across.
- Pivoted-arm lengths: 9" = 230 mm, 10" = 250 mm, 12" = 305 mm [K]; effective length = pivot-to-spindle + overhang [V S5/S6]. Baerwald suits 222-250 mm; Stevenson suits 200-230 mm effective [V S4].

### Arm geometry (the numbers a designer needs)
- Null points (independent of arm length): Baerwald (IEC/Löfgren A) 66.0 and 120.9 mm from spindle, peak error ~1.8 deg [V S3]; Stevenson 60.3 and 117.4 mm [V S3/S6].
- Overhang: Baerwald ~16.2 mm, Löfgren B 16.6 mm, Stevenson 14.4 mm [V S5, for the Pro-Ject test arm; overhang depends on arm length].
- Example 9" arm (230 mm effective): pivot-to-spindle ≈ 222 mm is a common spec only if overhang is ~8 mm, which is actually too small for a Baerwald alignment; real 9" arms are around 214-216 mm pivot-to-spindle (230 - ~15 overhang) [K, derived from overhang numbers above]. SL-1200 pivot-to-spindle is 215 mm, effective length 230 mm, overhang 15 mm, offset angle 22 deg, 2.0 deg-ish error [K, widely published; confirm in S1].
- Offset angle: ~22-23 deg for a 9" arm (cartridge face is turned inward toward the spindle). Longer arms have smaller offset: 12" ≈ 17-18 deg [K]. Offset = angle between the headshell axis and the line from pivot to stylus.
- Pivot position: on the right side of the deck, far from the spindle, roughly 215-222 mm from the spindle centre; the stylus is displaced past the spindle (overhang) so it reaches 60 mm from the spindle at inner groove and the arm swings through a ~25 deg arc.
- Tracking arc: the stylus path is a circular arc (radius = effective length) from outer groove (r~146-149 from spindle) to inner (r~60). Swing angle about 22-26 deg total (compute: angle at pivot = acos((L^2 + D^2 - r^2)/(2 L D)) for r = 148 and 60 with L=230, D=215: ~ about 29 deg to ~15 deg difference ≈ 14 deg for the music region; the arm never points at the spindle; at null points the headshell is tangent). Verify with the formula in the renderer. [D, formula standard law of cosines]
- Headshell: removable, ~52 mm long with 4-pin connector, finger-lift lip at the front (small L-shaped rail on the top left of the headshell, ~12 mm). Cartridge slotted holes allow ±8 mm adjustment. Colours: black, silver.
- Cartridge: ~17 x 17 x 25 mm, plastic body (often coloured; Ortofon Concorde has a distinctive coloured body with the white/red code), mounted with 2 screws 12.7 mm (0.5") apart in the standard mount [K]. Stylus protrudes at the front ~6-8 mm, with a slim cantilever, a small bright diamond tip (visible only as a short silver line and dot); stylus guard sometimes.
- Counterweight: cylindrical mass at the rear (~40-50 mm dia, ~25-30 mm long), ring-shaped around the arm tube, black/ silver with a scale ring marked 0-5 g; the weight rotates and the number aligns to a line on the arm. Technics: counterweight with a scale where 0 is the balanced zero and ~2 g typical. Top-view: a rectangle with ribbing, black body, white scale numbers.
- Anti-skate dial: small knob near the arm pivot base, 0-5 (grams) scale, usually a ~20 mm circular dial with white marks and a pointer. Technics: a slider/dial at the pivot base.
- Arm rest and clip: a post on the plinth to the right of the platter (≈ 20-25 mm tall), with a U-shaped cradle/ rubber pad; a clip holds the arm tube. Positioned along the arm's parked angle, roughly outside the record, at about 30-40 mm to the right of the platter rim.
- Arm lift / cueing lever: a small lever on the pivot base (top-view: short horizontal lever ~25 mm long). On the Technics: a lever on the arm base at the front-right with a UP/DOWN marking; the lift fork lifts the arm tube about 8-12 mm; damped silicone oil gives a slow ~1-3 s descent.
- Controls (Technics layout): large START/STOP button at front-left; 33 and 45 speed buttons (with a small LED); pitch fader ±8 % (Technics: ±8 % and ±16 % selector) at the lower-right (long slot ~100 mm with a centre detent, fader cap ~12 x 18 mm with an LED indicating quartz lock); a strobe/ target light: small pop-up lamp at the front-left of the plinth, in the rear-right corner on some models, that shines on the platter edge dots; the stylus (target) light: a gooseneck lamp near the arm, often a small LED on the rear right, illuminating the groove.
- Dust cover hinges: two hinges at the rear edge (≈ 100 mm in from each corner), brushed metal cylinders ≈ 25 mm long on the plinth rear; cover is clear acrylic.
- Feet: four rubber/ metal feet at the corners (≈ 55-60 mm round); top-view they're hidden, only visible in shadow as a darker offset under the corner. On the SL-1200 they are tall rubber cylinders (~15 mm radius).

## 2. Motion and behaviour

### Speeds
- 33⅓ rpm = 0.5556 rev/s = 3.333 deg per frame at 60 fps... precisely 200 deg/s (33.333 x 6) → 3.33 deg per frame at 60 fps. 45 rpm = 270 deg/s → 4.5 deg/frame. 78 rpm = 468 deg/s (7.8 deg/frame; 7.8 deg/frame is close to aliasing visually with 60 fps dot patterns, so fade the strobe).
- Pitch ±8 % [V S1: quartz-locked ±8 % range]; ±16 % on the "wide" setting for the MK2? Some retailers list ±8/±16 [V search]. Draw ±8 as the primary fader range.
- Spin direction: records and platters spin clockwise viewed from above [K, standard for all conventional turntables; 33⅓ rpm record goes from outer to inner].

### Start-up and brake
- Direct drive: reaches full speed in ~0.7 s at 33⅓ (Technics spec: ≤0.7 s start-up torque 1.5 kg-cm) [K from Technics specs; the user's brief states ~0.7 s]. Braking: quartz decks brake in ~1-1.5 s electronically.
- Belt drive: typically 3-10 s to reach speed; inertia coast-down when switched off 15-30 s (heavy platter) [K]. Ease in with an exponential rate: ω(t) = ω_target (1 - e^(-t/τ)) τ ≈ 1-2 s for belts, ~0.2 s for direct drive.
- Brake on DD: a strong decel curve, near linear in ~1.2 s with a very slight rebound; on belt decks, free spin-down.

### Tonearm movement
- Lift/cue: the lever raises the arm ~8-10 mm; descent through viscous damping (silicone oil) takes ~1-3 s with an ease-out curve; the first touch is a small bounce.
- Sweep: with a 20-25 minute side at 33⅓ rpm, the stylus travels from r ≈ 146-148 mm to r ≈ 60-65 mm: in angular terms the arm rotates ≈ 14-17 deg over the side; speed is a constant r-time relation: groove pitch ≈ 0.1-0.2 mm per rev so ~700-800 revolutions for 22 minutes [D: 22 min x 33.3 rpm = 733 rev; (148-62) mm / 733 = 0.117 mm per rev]. Use linear interpolation of radius with track progress, with slight modulation through gaps between tracks.
- Lead-in: the first revolution(s) the stylus moves faster through the lead-in spiral (~7 mm/0.5 rev... about 2-4 revolutions at much wider pitch, ~5-10 s) before groove pitch settles; the run-out is a faster spiral to a locked groove at r≈ 58-60 then to the end (the arm slowly oscillates ± 0.1 mm with the eccentric groove, i.e. a visible slight 'thump' per revolution) [K].
- Auto-return (automatic decks): at the run-out the arm lifts, swings back to the arm rest in ~2-3 s with an ease-in-out and sets down on the rest; a mechanical cycle noise. Manual decks leave the stylus in the locked groove.
- Strobe visual: the strobe pattern lit by mains light appears stationary at the right speed because the dot pitch equals the lamp flash cadence, i.e. the platter advances exactly one dot pitch per flash [D: see counts above]. If the platter is slow, dots drift backward (anticlockwise); fast, forward. The apparent drift rate = (speed error) x dot count; at +1 % that's ~1.8 dots/sec for the 180-dot row [D: 180 x 0.01 x 0.5556 rev/s = 1.0 dot/s]. Render by drifting the dot row phase at that rate, don't rotate it with the platter.
- Wow and flutter: Technics ~0.025 % WRMS; cheap belt decks 0.1-0.25 % [K]. Visual: eccentricity of 0.1-0.3 mm on a cheap/ warped record produces a small once-per-rev lateral stylus oscillation and visible edge wobble; platter wobble of ±0.2-0.5 px at 1 rev/s; warped record causes a gentle once or twice per rev vertical bob (hard to see from above, but reflect it in highlight width).

## 3. Rendering techniques (top-down 2D)

What is fixed relative to the light (world) versus what rotates:
- ROTATES with the platter/record: label artwork, text, strobe dots (except apparent drift), mat logo, rim marks, spindle slot patterns, any scratches/ dust specks, record-edge bevel texture.
- STAYS FIXED (world space): all light streaks and specular highlights on grooves, brushed-metal reflection on a rotating disc (a spinning anisotropic surface looks the same at every instant since it's rotationally symmetric), drop shadows (cast direction fixed), the lamp glare, tonearm and chrome highlights.
- Rule: never rotate a gradient or a highlight layer; rotate only the textures with non-symmetric detail. In SwiftUI: apply `.rotationEffect` only to the label/dots layer, not to the group that contains the light streak overlays.

### Brushed aluminium
- Use an AngularGradient (conic) with multiple narrow stops cycling light/dark, centred on the platter centre: e.g. stops at 0°: 0.62, 20°: 0.88, 40°: 0.55, 90°: 0.70, 140°: 0.92, 180°: 0.60, ... for a rim lit from one side. Overlay a faint ring noise (repeated thin strokes of alpha 0.03-0.06) for fine concentric brush marks. Because the metal is turned on a lathe, the grain follows circles, so streaks fan out as bright wedges (two opposed bright lobes).
- Fixed: the angular gradient remains static even as the platter spins; only the strobe dots rotate over it.

### Grooves, dead wax and label
- Grooves: draw 60-150 concentric thin circles with alpha 0.02-0.06 stroke, with varied radii spacing grouped in bands for tracks; avoid drawing thousands of rings (use a repeating radial gradient or a pre-rendered image/ Canvas pattern).
- Light streak on vinyl: two (or one) wedge-shaped soft highlights (AngularGradient, mask to the ring r 60-148), brightest along the direction toward the light, fading to black over ~40-60 deg; fixed in world space.
- Dead wax: smooth gloss band r 50-60 with no ring texture, a single thin groove (locked groove) at r ~58, tiny matrix text etched (rotates with record).
- Label: flat colour with print (rotates), a thin 0.5 mm raised ring outline, spindle hole 7.26 mm punched with a dark soft-edge.
- Record edge: a thin lighter rim line (1-1.5 px) and a darker ring just inside the lead-in.

### Knurling on knobs
- Radial tick marks around the circumference: 40-80 short strokes with alternating light/dark; add a conic gradient on the cap for the flat top; hairline highlights offset toward the light.

### Shadows and ambient occlusion
- Soft shadows: offset along the light direction (e.g. 6-10 px down-right for a top-left light), blur radius proportional to height; the tonearm shadow is longer and softer than the platter's. Contact shadows: tight 1-2 px dark ring where the record meets the mat, and where the clamp rests.
- AO: radial gradient dark vignette around the platter well in the plinth, darker at the plinth recess; add a thin bevel highlight on the upper-left edges and darker on the lower-right.
- The tonearm raised by the lift: the shadow detaches (offset grows) when lifted, nearly touching when lowered. This gives the depth cue for cueing.

### Chrome and specular highlights
- Chrome: linear/ radial gradient with hard-edged bands (white, dark grey, white, mid grey) and a tiny white specular dot; on cylinders (counterweight, spindle, tube) the bands run along the long axis.
- Keep the specular dot fixed in world space even for rotating circular knobs.

### Wood grain and plastics
- Wood veneer: layered lines with low-frequency noise (use Canvas with sinusoidally displaced parallel lines, 2-3 tones, plus a thin lighter edge); grain runs along the plinth width. Satin lacquer: add a broad soft highlight band diagonal.
- Matte plastic: flat colour with a tiny noise texture (alpha 0.03) and a soft bevel; gloss plastic: strong, narrow highlight following the edge and a faint reflection gradient.

## 4. Accuracy pitfalls
1. Arm pivot placed on the platter's centreline or directly right of the spindle at the wrong distance: the pivot sits ~215-222 mm from the spindle for a 9" arm, usually rear-right, not in line with the spindle.
2. Arm pointing straight at the spindle: it must not. The stylus is offset (overhang ~15 mm past the spindle distance) and the headshell is angled ~22 deg inward; the line pivot-to-stylus passes at an angle.
3. Platter smaller than the record on a DJ deck, or the same size on hi-fi: platter ~332 mm vs record 302 mm (SL-1200), i.e. the platter shows ~15 mm outside the record all round.
4. Highlights on the record rotating with the disc: the streaks must be fixed.
5. Spin direction: clockwise when seen from above [K].
6. Wrong strobe counts or non-integer bars; the four rows need 180/133/216/160 dots; each row's dot size differs.
7. Record spindle hole larger than the spindle, label bigger than ~100 mm, dead wax missing, groove rings too bold or too uniform.
8. The tonearm moving out to the label or past the dead wax, or sweeping beyond r = 60 mm; the arm should park on the rest outside the record when idle.
9. Missing counterweight at the rear or the anti-skate dial; or a counterweight in front of the pivot.
10. Perfectly flat, no shadow depth; no height cue for the lifted arm; platter with no mat.
11. Tonearm length mismatched to plinth: with a 230 mm effective arm, the pivot-to-platter-centre distance is ~215 mm so the pivot lies just past the plinth edge region of the platter; ensure the plinth is wide enough (453 mm w/ 332 platter leaves ~60 mm each side).
12. Strobe dots rotating normally under mains light show a steady pattern only at the right speed; don't animate them with the rotation unless demonstrating drift.

## Caveats
Web search in this session returned results mostly from snippets; items tagged [K] are conventional figures that should be cross-checked against the SL-1200 service manual (S1) and the RIAA bulletin (S2) before being locked into the design. Where a figure in the commissioning brief conflicted with a source (SL-1200 depth 360 not 353; pivot-to-spindle 222 with 230 mm effective implying only 8 mm overhang) the source figure is used and flagged.
