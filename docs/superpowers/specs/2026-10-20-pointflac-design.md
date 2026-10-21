# pointFlac — v1 design

**Date:** 2026-10-20
**Owner:** Kiran P Jose (GitHub: `kiraa06`)
**Status:** Draft for review.

How to read this document:
- Decisions Kiran made are stated plainly.
- My own calls are marked **[call]**. Kiran can override any of them.
- Things the builder decides are marked **[builder]**.

---

## 1. Intent

pointFlac is a native iPhone music player for people who listen seriously every day: music creators and audio enthusiasts on wired IEMs and USB DACs. It plays FLAC with nothing lost, up to 32-bit integer. It always says exactly what is happening to the signal. It wraps that in a tactile vinyl ritual that should appeal to long-time hi-fi people and newer listeners alike.

It borrows its ideas from two projects:
- [Runout](https://github.com/Abhiroop1122/runout) (Android): the crate, the glass turntable, records with sides, the 32-bit float DSP sink, and "honest labels".
- [Somchandra17's fork](https://github.com/Somchandra17/runout) (Android, v0.4.1): FLAC-only admission checked against real bytes, unified search, Soulseek and Internet Archive downloads, and staged-then-validated publication.

pointFlac borrows ideas only, never code. It is a new project, written from scratch in Swift, in a new public repository.

### Why

Existing iOS players fall into two groups:
- Accurate but dated, so not pleasant to open every day.
- Pretty but vague about whether you actually get your file's full resolution. Apple Music, for example, fails bit-perfect tests over USB.

Kiran wants one app that is both trustworthy and beautiful, and fast above all.

### Success looks like

- Kiran uses it daily on his iPhone as his main player.
- With a 32-bit-capable USB DAC dongle and IEMs, a 32-bit/96 kHz FLAC reaches the DAC untouched at 96 kHz, and the app shows that truthfully.
- It never feels slow. Every interaction meets the budgets in §8.
- The codebase is easy to read and well tested, so new features (sharing, a Mac version) can land without fear.

### Anti-goals (failures even if it "works")

1. **Slow.** Any lag in launching, search, scrolling, animation or playback start. Kiran named this as the thing that would make him wince.
2. Showing a quality label it can't back up, such as "bit-perfect" when that can't be known.
3. Changing the signal without saying so.
4. A codebase that's dense and hard to follow. The fork's style is a cautionary example.
5. Social or sharing features crowding out quality in v1.

---

## 2. Scope

### In v1

- **Platform:** iPhone, iOS app only.
- **Playback:**
  - FLAC only: 16, 24 and 32-bit integer; 44.1–384 kHz; mono and stereo.
  - Gapless playback, including across sides.
  - Play continues automatically from side to side (Kiran decided). After the last side, it moves to the next record in **Up Next** **[call]**.
  - An **Up Next** queue with "Play next" and "Add to queue" on albums and songs, plus repeat (album / one) **[call]**. Shuffle comes later.
  - Background audio, lock screen and Control Center controls.
- **Player:** two views with a switch:
  - **Deck:** the interactive glass turntable.
  - **Cover:** editorial big-artwork view.
- **Shelf:** a 3D crate for browsing, plus instant search. The record travels from the crate onto the deck with an animation.
- **Library:**
  - Import from the Files app: On My iPhone, iCloud Drive, USB drives and network shares.
  - Downloaded music lives in the app's own folder, which is visible in Files.
- **Downloads:**
  - Internet Archive (FLAC only) in every build.
  - Soulseek search and download as an optional module, search and download only with no sharing.
    - **Included** in local builds and in the public GitHub release `.ipa` (Kiran decided).
    - Compiled **out** of any build that goes through Apple review (TestFlight, App Store).
- **Sound section (DSP):** parametric EQ, AutoEq headphone correction, ReplayGain with loudness scanning, crossfeed, tilt/warmth, limiter, high-quality resampling, level-matched A/B bypass, and per-device profiles. A single **Pure** switch turns everything off.
- **Signal readout:** the file's format, what pointFlac sends, the hardware sample rate, and whether processing is active.
- **Testing:** thorough automated tests, including bit-exact pipeline tests and performance budgets that fail the build when broken.

### Not in v1 (planned for later)

- Public sharing, friends, profiles, Nostr, private messages, and `.vinyl` packages.
- Soulseek uploads and sharing.
- Mac app. The architecture must allow it without rewriting the audio or library layers.
- iPad layouts **[call]**: the app runs on iPad, but iPhone layouts come first.
- TestFlight and App Store, once Kiran has an Apple Developer Program membership.
- CarPlay, AirPlay-specific features and lyrics.

### Explicitly never

- Ads, analytics or tracking SDKs, or a pointFlac account server.
- Any format other than FLAC for music. Artwork images are fine.

---

## 3. Constraints and facts the design rests on

### 3.1 Distribution (decided)

- Kiran has **no paid Apple Developer Program membership** yet. For v1:
  - **His own iPhone:** Xcode installs pointFlac with his free Apple ID. The install expires every 7 days, so he reinstalls weekly.
  - **Other people:** every GitHub release includes an unsigned `.ipa` that they sideload with AltStore, SideStore or Sideloadly. Those tools re-sign it with the user's own Apple ID and need the same 7-day refresh. The README explains how.
  - **Later:** when Kiran joins the program, the README switches to a public TestFlight link, and then the App Store follows.
- **App Store reality:** Apple guideline 5.2.3 bars apps that facilitate illegal file sharing or download media from third parties without authorization. No Soulseek client has ever been on the App Store; the 2008–09 iPhone clients were jailbreak-only. A public TestFlight link also goes through Beta App Review. Therefore:
  - The Soulseek module is a **compile-time option**. Any build that goes through review must not contain it.
  - Sideloaded GitHub releases are not reviewed, and Kiran chose to include Soulseek in them. The Soulseek code lives in the public repo.
  - Internet Archive downloads are App-Store-safe, because the albums are Creative Commons licensed.
- **Xcode is not yet installed** on Kiran's Mac (macOS 26.4, Apple Silicon; only the command-line tools are present). Installing it is the first setup step.
- **Kiran's phone:** iPhone 17 Pro (120 Hz ProMotion, USB-C) on the **latest iOS beta**.
  - Installing on a beta OS needs an Xcode version that supports it, which is usually the matching Xcode beta.
  - **[builder]** Confirm which Xcode supports his iOS build, and whether it requires updating macOS from 26.4.

### 3.2 iOS audio realities

These come from research on 2026-10-20 and must be confirmed by spikes (§10).

- **32-bit FLAC decoding:** the reference libFLAC has supported 32-bit integer samples since 1.4.0 (2022); 1.5.0 is current. pointFlac bundles libFLAC (BSD licence) and uses it for every FLAC.
  - **Apple's decoder can't do 32-bit.** In a test on macOS 26.4 it decoded a 24-bit/96 kHz FLAC bit-identically, but failed on a 32-bit/192 kHz FLAC with every client format, even though it identified the file correctly. iOS is assumed to behave the same.
  - The single-file `dr_flac` decoder also can't do 32-bit: it rejects 33-bit side channels.
- **Bit-perfect USB output is possible, but depends on how the app is built:**
  - On an iPhone 16 Pro running iOS 18.1.1 with an RME ADI-2 DAC, which has a hardware bit-perfect test, Onkyo HF Player passed at 16, 24 and 32 bit across rates up to 192 kHz.
  - Neutron and Apple Music failed. Apple Music delivered 24-bit files as 16-bit.
  - In all three apps the DAC's sample rate followed the file.
  - pointFlac must reproduce Onkyo's result, not Apple Music's.
- **Sample rate:** the app asks iOS for each file's rate (`AVAudioSession.setPreferredSampleRate`). That is a *hint*, so the app must read back the actual rate after activation and react to it:
  - USB DACs generally follow the file up to their maximum.
  - Some small dongles only accept 48 kHz, or 44.1 and 48.
  - The phone's own output is 44.1 or 48 kHz.
- **Bit depth reaching the DAC:** there is no public iOS API to read or set it, or to list a DAC's supported rates. Vox's developer says the same. What an app *can* read:
  - the sample rate
  - the channel count
  - the port type (`.usbAudio`)
  - the system volume level, read-only

  The readout must not claim a DAC bit depth it can't measure (§5.7).
- **Volume:** apps can't set the system volume. Whether iOS forwards volume changes to a DAC's own volume control or scales the samples digitally isn't documented. pointFlac warns when the system volume is below 100% on a USB route, because digital scaling would break bit-perfect output.
- **Float32 vs 32-bit:** iOS's standard Float32 path carries ≤24-bit samples exactly at unity gain. Only 32-bit sources need a different path; spike S1 tests an Int32 client format on RemoteIO.
- **Kiran's current output is Apple EarPods.** Independent tests show both the USB-C and Lightning versions cap at 24-bit/48 kHz. So for v1 on his hardware:
  - 16/44.1 and 24/48 files can be bit-perfect, switching between 44.1 and 48 kHz.
  - Higher-resolution files are resampled by pointFlac (high quality), and the screen says so.
  - The full 32-bit path is for 32-bit-capable USB DACs, which Kiran expects to use.
- **Background limits:** iOS has no persistent background service.
  - The app keeps running in the background while it is playing audio.
  - Internet Archive downloads can use background `URLSession`.
  - Soulseek peer connections only live while the app is in the foreground or playing.
  - **[builder]** Evaluate iOS 26's `BGContinuedProcessingTask` for user-started Soulseek downloads. It is unverified for long-lived sockets.

### 3.3 Legal and licensing

- pointFlac is **MIT licensed**.
- Only permissively licensed code is linked: MIT, BSD, zlib, Apache-2.0 or public domain. GPL, LGPL and AGPL projects (Seeker, Nicotine+, Soulseek.NET, slskd, Rockbox, JamesDSP, Equalizer APO and others) are reading material only. The library survey (§11) lists each library's licence.
- Reverse engineering with REA is for learning how shipped software behaves, for example Mac players for the later Mac version. It never copies proprietary code. App Store iOS binaries are encrypted and are not analysed.

---

## 4. Product design

### 4.1 App map

- **Player** (the home screen):
  - The **Deck / Cover** switch at the top.
  - Track title and artist, the signal strip, the progress bar and transport controls.
  - Swipe up from anywhere on the player to open the **Shelf**.
- **Shelf:** a sheet with:
  - search at the top
  - filter chips: All · Albums · Songs · 24-bit+ · 32-bit · ≥96 kHz
  - the 3D crate
  - search results below the crate
- **Get music:**
  - **[call]** Reached from the Shelf with an "Add music" button and from the empty state.
  - Import from Files.
  - Internet Archive: search plus a curated **Friday Drops** shelf.
  - Soulseek, when the module is compiled in.
- **Downloads:** one transfer list with pause, resume, retry and cancel. A badge on the Shelf shows activity.
- **Sound:** the DSP section, Pure mode and per-device profiles.
- **Settings:** library folders, Soulseek account, storage, about and licences.

**First run.** Kiran currently has no collection, so the empty state must make getting music the obvious next step:
- "Add music from Files"
- "Browse Internet Archive"
- "Search Soulseek", when that module is present

**[call]** One minimal welcome screen, then straight into the player with an empty platter that invites you to add a record. No multi-step onboarding.

### 4.2 The player: shared elements

Both views share the same layout below the visual. Only the visual area (the "stage") changes.

- Title in bold display type, and the artist.
- Side and track line, e.g. "Side A · Track 2".
- **Signal strip:** `FORMAT · DEPTH · DAC · SIGNAL`, for example `FLAC · 32-bit · 96 kHz · ● Pure`. Exact rules in §5.7.
- Progress bar with elapsed and remaining time, using a monospaced font.
- Transport: previous, play/pause and next.

**Appearance:**
- Both views follow the phone's light/dark setting (Kiran decided). That makes four designed looks:
  - **Deck light:** frosted glass, as in the mockups.
  - **Deck dark:** smoked glass, chrome and a dimmer pastel glow. Not yet mocked up; design it early.
  - **Cover dark:** editorial, as in the mockups.
  - **Cover light:** editorial on paper-white, with the colour wash from the art.
- **[call]** An appearance override in Settings: System / Light / Dark.
- **[call]** Use Liquid Glass materials throughout.
- **[call]** The minimum iOS version is 26. It avoids fallback code, and Kiran runs the latest beta.

### 4.3 Deck view: the interactive turntable

The Deck is played by hand, precisely. It is a frosted glass plinth with:
- a strobe-dotted platter
- the record (every album with art is a picture disc; the art turns under grooves, with a still light sheen)
- an S-shaped tonearm
- a small dot-matrix screen showing track code, title, artist, time, and the rate and depth

Gestures:

| Gesture | Effect | Precision aids |
|---|---|---|
| Drag the **tonearm** | Coarse seek across the whole side. Let go to drop the needle. | A loupe shows the track code, time to the millisecond and the waveform under the needle. The needle snaps into the gaps between tracks with a haptic tick. |
| Turn the **record** with a finger | Fine scrub, like a jog wheel. One turn = 1.8 s (33⅓ rpm), so small turns move by fractions of a second. Audio follows the hand. | The loupe shows the scrub offset (e.g. `−3.250 s`) and the resulting time. |
| Hold the record still | Stops the record, with a wind-down. Release and it spins back up. | — |
| Tap the record while the needle is up | Turns the record over to the next side. | — |
| Tap the tonearm while it's at rest | Drops the needle at the start of the side. | — |
| Previous / next | Moves between tracks, crossing sides as needed. | — |

**End of side:** play carries on (Kiran decided).
- The audio continues gaplessly into the next side.
- The deck shows a brief automatic flip over the playing audio: tonearm lifts, record turns, needle returns to the lead-in. The audio never pauses for the animation.
- After the last side, the next Up Next record is pulled from the crate with a short version of the hand-off animation. With an empty queue, the needle lifts and play stops.

**Tapping a song** in search or the shelf loads its album, cues the right side and plays from that song, then carries on through the album **[call]**.

**Rules:**
- Scrubbing and holding the record change the sound only while your finger is down. The signal strip shows `● Scrubbing`, then returns to its normal state.
- No 45 rpm switch and no pitch fader **[call]**: speed changes alter the signal, which goes against "unfiltered pure". They could return later as an explicitly impure "fun" mode.
- Sides follow Runout's model:
  - at most about 22 minutes per side
  - tracks are never split across sides
  - sides are balanced by duration
  - double albums get sides A–D
  - **[builder]** Albums with two or more tracks always get at least two sides; one-track albums get one side.
- Turntable sounds (needle drop, runout groove) are optional and **off by default** **[call]**. They are never mixed in Pure mode.

### 4.4 Cover view

- Large artwork with the record peeking out of the sleeve.
- A background wash taken from the cover colours.
- Bold editorial type and the same shared elements.
- Quiet and fast; no deck gestures.
- Switching views animates the record into its sleeve and grows the sleeve into the cover, or the reverse.

### 4.5 Crate → deck hand-off (signature animation)

Tapping a sleeve in the crate starts this sequence. Timing is Kiran's choice: the **3× slow-motion pace of the browser sketch**, about 3.5 s until the platter spins, with the tonearm settling at about 4.7 s.

| Step | Time (approx.) | Motion |
|---|---|---|
| 1 | 0–0.5 s | The sleeve lifts toward you, with a light haptic tap. |
| 2 | 0.5–1.4 s | The record slides up out of the sleeve. |
| 3 | 1.35–2.9 s | The shelf sinks away. The record arcs up to the platter, growing to platter size and turning as it goes. |
| 4 | ~2.9 s | It lands on the spindle with a small spring settle and a soft haptic thump. The dot-matrix screen wakes up. |
| 5 | 3.45–4.7 s | The platter spins up and the tonearm swings to the lead-in. |

Requirements:
- Runs at 120 Hz on ProMotion screens with spring physics and **zero dropped frames**. Artwork and disc textures are ready before the tap.
- **Interruptible.** You can grab the record mid-flight and carry it yourself. Dropped off the platter, it springs back into its sleeve.
- **[call]** A second tap finishes the animation instantly.
- Respects Reduce Motion: a short cross-fade instead.

Reference sketch: `.superpowers/brainstorm/…/crate-to-deck-v1.html`, played at "Slow-mo ×3".

### 4.6 Shelf and search

Kiran types an artist or album name and expects results instantly as he types.

**Local results:**
- Update on every keystroke, on screen within one frame (§8).
- Matching is case-insensitive and ignores accents and punctuation.
- Matches can be prefixes or whole words, with tolerance for one-letter typos.
- Matching letters are highlighted.
- Results are grouped as albums, artists and songs.

**Online results [call]:**
- Start by themselves after typing pauses for about 0.6 s with at least 3 characters. Pressing Search starts them immediately.
- Stream in below the local results, each labelled with its source (Internet Archive or Soulseek).
- A new phrase cancels the previous online search.
- Soulseek searches are rate-limited, with at least a few seconds between them, so the network isn't flooded and the account isn't throttled.

**Filters:** All · Albums · Songs · 24-bit+ · 32-bit · ≥96 kHz. Each is one tap.

**Crate:**
- Sleeves stand in perspective; the one in the middle faces you.
- You flick to browse; momentum snaps to a sleeve.
- The caption under the front sleeve shows title · artist · year · quality · position (e.g. `3 of 41`).

### 4.7 Getting music

**Import from Files** (every build):
- **Add folder:** keep files in place; pointFlac remembers access to that folder.
- **Import files:** copy them into pointFlac's own library folder.
- Every file is checked against its actual bytes (§5.3). A renamed MP3 is rejected with a clear reason.
- iCloud Drive files that aren't downloaded are fetched before playback, and their cloud state is shown.

**Internet Archive** (every build):
- Search only shows items that genuinely contain FLAC files, confirmed against the item's file list before showing **Download**.
  - Search uses the scrape API, which pages with a cursor; the older advanced-search API stops at 10,000 sorted results.
  - The item-level `format:"Flac"` / `"24bit Flac"` filter can match on derivatives such as zipped FLAC. So the metadata API's file list is the source of truth. Keep only files that:
    - have format `Flac` or `24bit Flac`
    - are `source == "original"`
    - have a `.flac` name
  - Each file entry lists its size and MD5. pointFlac checks downloads against both before publishing.
- **Licence filter [call]:** show only items with an open licence (Creative Commons or public domain) or from the Live Music Archive (`etree`), whose bands allow trading. Items with no licence data are hidden. The review safety argument in §3.1 depends on this, and some Archive uploads are commercial albums.
- A **Friday Drops** shelf shows ten Creative Commons netlabel albums each week, chosen from the week number as in Runout.
  - **[call]** Runout's "claim only 3" limit is dropped; that scarcity belonged to Runout's ritual, not to quality.
  - **[call]** The selection is snapshotted on first load each week, and the week runs on UTC.
- Downloads use background `URLSession`, a polite User-Agent and Archive's rate limits.
- Licence information is stored with each album and shown on the record.

**Soulseek** (optional module, in local builds and GitHub releases; never in reviewed builds):
- Sign-in with an existing account or creation of a new one, with the fork's honest warnings:
  - Soulseek has no password reset.
  - Signing in with a mistyped name creates a new account.
  - Credentials and messages travel unencrypted.
  - Signing in here disconnects other clients using the same account.
- Credentials are stored in the iOS Keychain (§7).
- Search results are grouped by peer and complete folder. Album folders are previewed (full FLAC listing) before downloading, as the fork does.
- No sharing in v1. The UI explains that some peers refuse uploads to users who share nothing.
- Transfers run while the app is in the foreground or playing (§3.2).

**Downloads list:**
- One list for both download sources.
- States: queued, downloading, paused, validating, saving, done, failed, cancelled.
- A download counts as finished only after it passes validation and is saved into the library (§5.4).

### 4.8 Sound section

Every effect is off by default; the default state is **Pure**. The section is laid out like a pro tool:
- a signal-flow diagram
- each block with its own on/off switch
- a level meter and clip indicator after processing

Blocks, in processing order:

1. **ReplayGain:** off, track or album mode.
   - Uses existing tags.
   - **[call]** "Scan loudness" computes EBU R128 values for untagged albums in the background and stores them.
2. **Preamp with automatic headroom:**
   - Pre-attenuates by the largest boost across the combined EQ curve, so EQ can never clip.
   - Manual trim is available.
   - A clip indicator lights if it ever overloads.
3. **Parametric EQ:**
   - Up to 20 bands. Filter types: peak, low shelf, high shelf, low pass, high pass, notch.
   - Each band has frequency, gain and Q; filters are designed for the actual sample rate.
   - A 10-band graphic mode with presets sits on top of the same engine.
   - A frequency-response graph you can drag directly.
4. **Headphone correction:**
   - A searchable headphone list from the **OPRA** database ([opra-project/OPRA](https://github.com/opra-project/OPRA)).
     - OPRA's data is CC BY-SA 4.0, and commercial use is allowed.
     - It requires the OPRA logo and credit to each preset's author in the UI.
   - Import any AutoEq `ParametricEQ.txt` file.
   - AutoEq's own results are **not bundled**: they carry no licence, and oratory1990's measurements prohibit unlicensed commercial use.
5. **Tilt / warmth:** a gentle tilt around about 1 kHz, plus Runout's "warmth" curve as a preset.
6. **Crossfeed** for headphones, with Bauer stereo-to-binaural presets.
7. **Limiter:**
   - Look-ahead, with a true-peak ceiling (default −0.3 dBTP).
   - Only active when needed. A gain-reduction meter shows its work.
8. **Resampler:**
   - High quality.
   - Used only when the output device rejects the file's rate, or when the user forces a rate.

**A/B bypass:**
- Hold to hear the unprocessed signal, with **level matching** so louder doesn't fool you.
- A blind A/B mode is a stretch goal.

**Per-device profiles:**
- Settings are remembered per output device (for example, a USB DAC model versus AirPods) and switch automatically on connect.

**Pure mode:**
- One tap. It bypasses every block, all turntable sounds and any rate forcing.
- It asks iOS for the file's native rate.
- It is the default state.

### 4.9 Visual system

- Two signature looks, each in light and dark:
  - **Deck:** frosted glass, chrome and pastel light behind the glass.
  - **Cover:** editorial dark, with colour taken from the artwork.
- Typography: a clean grotesk for UI and titles, a monospaced font for numbers and signal data, and a pixel font for the deck's dot-matrix screen.
  - **[builder]** Choose openly licensed fonts. Inter and Silkscreen (both under the SIL Open Font License) are Runout's choices and are acceptable.
- **Motion principles:**
  - Every movement is physical: springs, momentum and inertia.
  - Every animation can be interrupted.
  - Haptics mark the moments that matter (snap, land, track gap).
  - Never block input while something animates.
- **Accessibility:**
  - Full VoiceOver labels for every deck control, with an accessible alternative for each gesture (seek slider, step buttons).
  - Dynamic Type everywhere except fixed-size skeuomorphic labels.
  - Reduce Motion and Increase Contrast are respected.
- Reference mockups: `.superpowers/brainstorm/…/hybrid-v1.html` and `deck-interactions-v1.html`.

---

## 5. Technical design

### 5.1 Architecture

- A single Xcode app target, plus **local Swift packages**. Each package has one job and a small public API.
- Everything except the UI shell compiles for macOS too, ready for the later Mac app.

| Package | Responsibility |
|---|---|
| `PFCore` | Models (Track, Album, Side, AudioFormat, SignalState), side-splitting, errors and shared utilities. No UI and no I/O. |
| `PFFlac` | libFLAC wrapper: metadata, the byte-level validation rule, a streaming decoder to integer PCM, seeking, and MD5 verification. |
| `PFAudio` | Playback engine:<br>• the scheduling queue (gapless)<br>• the output path with sample-rate negotiation<br>• route, interruption and background handling<br>• Now Playing and remote commands<br>• the signal-state reporter |
| `PFDSP` | Processing blocks, the processing graph, resampler, loudness measurement, meters and A/B. Pure-function cores that are easy to test. |
| `PFLibrary` | Database, importing (Files, bookmarks, iCloud), validation pipeline, artwork cache and file watching. |
| `PFSearch` | Search index and ranking. Takes the library snapshot; returns ranked results. |
| `PFDownloads` | Download orchestration: queue, states, staging, validation and publishing into the library. The provider protocol is defined here. |
| `PFArchive` | Internet Archive provider: search, metadata, file selection and download. |
| `PFSoulseek` | Optional. Soulseek provider over the native core (§5.6). Excluded from builds via a build flag. |
| `PFDesign` | Design system: colours, type, materials, haptics, motion springs and shared components. |
| `App` | SwiftUI screens and view models: Player (Deck, Cover), Shelf, Get Music, Downloads, Sound and Settings. |

Rules:
- Dependencies point one way: `App` → features → `PFCore`. Feature packages don't depend on each other except through `PFCore` protocols.
- Concurrency uses Swift 6 strict concurrency.
- Nothing slow runs on the main actor; audio work runs on a real-time-safe path.
- **[builder]** Pick the state-management style. Plain `@Observable` view models are the default; avoid heavy frameworks.

### 5.2 Audio pipeline

```
file ─▶ PFFlac decode (int16/24/32) ─▶ [Pure: no-op | DSP graph in Float64] ─▶ output format ─▶ iOS output unit ─▶ device
```

**Decode:**
- libFLAC streaming decode on a background decode thread, into lock-free ring buffers.
- Read-ahead is sized to absorb file-system and iCloud latency.

**Engine [call]:** pointFlac's own small engine on libFLAC.
- [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) (MIT) is the main reference, and code can be borrowed with attribution. It is not adopted as-is for three reasons:
  - its output always converts to Float32 and goes through iOS's main mixer, so it can't carry 32-bit
  - its gapless playback only works when formats match
  - as shipped, it pulls in LGPL libraries (lame, mpg123, libsndfile, TagLib and others)

**Output path:** the core requirement is to reproduce Onkyo's bit-perfect result.
- For ≤24-bit sources, a Float32 client format at unity gain is exact.
- For 32-bit sources, spike S1 tests a RemoteIO output with an Int32 client format, where the client rate always equals the hardware rate. RemoteIO silently resamples if they differ.
- **[builder, after S1]** Finalise RemoteIO vs AVAudioEngine.
- **If S1 shows 32-bit can't be passed untouched [call]:** that is an accepted, disclosed limit, not a project stop. Kiran's own goal was 32-bit "up to near perfection", and 24 significant bits is far below any DAC's noise floor. The readout then says exactly what happens.

**Bit-depth reduction [call]:** when the device or path can't take the file's depth (e.g. a 32-bit file on EarPods), pointFlac reduces the depth itself with TPDF dither rather than letting iOS truncate, and the strip says so (§5.7).

**Audio session:** category `.playback`, mode `.default`, policy `.longFormAudio`. Preferred rate is set before activation, or with deactivate → set → reactivate when the rate changes, then read back.

**Sample-rate negotiation:**
1. Before starting a track, request the file's rate.
2. Read back the actual hardware rate.
3. If they differ, apply the policy:
   - Pure on: use the high-quality resampler in `PFDSP` and show it. Never let iOS resample silently.
   - Pure off: same.
4. Rate changes between tracks of different rates must be glitch-free. A short silence is acceptable if a click would otherwise occur; the transition is documented.

**Gapless:** the next track is decoded ahead, and tracks join sample-accurately when the format matches. If the rate differs, renegotiate at the boundary (a short gap is acceptable and logged).

**Seek:**
- Sample-accurate through libFLAC seek tables or binary search.
- Scrubbing produces the jog-wheel sound by varying the read rate through the resampler, while the finger is down only.

**Routes and interruptions:**
- Unplugging the device pauses playback (standard iOS behaviour).
- Calls and Siri interrupt cleanly and resume when appropriate.
- A new device triggers its per-device profile and a fresh rate negotiation.

**Volume:**
- pointFlac has no digital volume in Pure mode.
- The signal readout's help explains how to get bit-perfect output: use the DAC's or amp's volume and keep the iPhone's volume at maximum when the DAC has no hardware volume.

**Signal-state reporter:** publishes a `SignalState` (§5.7) to the UI whenever anything changes.

### 5.3 FLAC admission rule

A file counts as music only if all of the following are true:
- its real name ends in `.flac`;
- its bytes start with `fLaC`, optionally after a valid ID3v2 prefix;
- the first metadata block is a valid 34-byte STREAMINFO:
  - minimum block size ≥ 16
  - maximum block size ≥ minimum
  - frame sizes are consistent
  - sample rate is 1–655,350 Hz
  - bits per sample are 4–32
- metadata blocks are well formed (at most 1,024 blocks, each at most 16 MiB);
- the first audio frame header is valid, including its CRC-8.

This is the fork's rule, re-implemented. It establishes the format, not where the recording came from.

Two extras:
- **[call]** An optional **Verify album** action fully decodes the files and compares each against the MD5 signature stored in its STREAMINFO. This gives an "audio intact" badge.
- Multichannel FLAC (more than 2 channels) is imported but marked "not supported in v1" **[call]**.

### 5.4 Library and storage

**Database:**
- SQLite is the single source of truth for library metadata. **[builder]** GRDB is the expected choice, pending §11.
- Tables: albums, tracks, files, folders and bookmarks, artwork, loudness, downloads and sources, plus play history (used for search ranking and the "recently played" order) and the Up Next queue (restored on relaunch).
- Migrations are explicit and versioned; there is never a destructive reset.

**Files:**
- `Documents/Library/` holds downloaded and imported-by-copy music. It is exposed to the Files app (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`).
- External folders are referenced by security-scoped bookmarks and rescanned on launch and on change.

**Staging and publication** (both download sources):
1. Download into a private staging folder.
2. Check size bounds.
3. Validate with the §5.3 rule.
4. Move or copy to the library under a temporary name.
5. Verify again.
6. Rename atomically.
7. Commit to the database.

Failures keep enough state to retry. Cancelling never deletes music that has already been published.

**Artwork:**
- Extracted once, then downsampled to the sizes the UI uses. Thumbnails, sleeves and the platter texture are stored separately.
- The decoded-image cache is limited **by bytes, not by count**. This fixes Runout's out-of-memory risk.

**Identity:** a file is identified by its bookmark or path plus its size and a hash of its first audio frames, so renames and moves don't lose ReplayGain or play history.

### 5.5 Search engine

- **[call]** The index is in memory and rebuilt incrementally from the database:
  - normalised fields: NFD, accent-stripped, case-folded, punctuation collapsed
  - prefix trees or sorted arrays for prefixes
  - word sets for whole-word matches
  - a one-edit typo pass for tokens of 4 or more characters
- **[builder]** The alternative is **GRDB (MIT) + the system SQLite's FTS5 + SymSpell**:
  - FTS5 with `unicode61 remove_diacritics 2` and `prefix='1 2 3'`, ranked by column-weighted bm25
  - the trigram tokenizer for substring matches
  - SymSpell (MIT; Swift port SymSpellSwift) over the token vocabulary for typos

  Spike S5 benchmarks both approaches at 100k tracks, and whichever meets the §8 budget wins. Pin SymSpell to its MIT repositories; some older forks are LGPL.
- Ranking runs in this order:
  1. exact title match
  2. title word match
  3. title substring
  4. artist or album word
  5. typo match
  6. tie-breakers: quality (higher first, only when the filter favours it) and recently played
- Online result streams merge without re-running local matching: local results are computed once per query, and remote batches are appended (a lesson from the fork).

### 5.6 Soulseek module

**Core [call]:**
- **First choice:** [seeleseek](https://github.com/bretth18/seeleseek)'s `SeeleseekCore` package. It is MIT, Swift 6, uses Network.framework, has no dependencies, declares iOS 18, and was active in October 2026. Extract it and leave out its sharing.
- **Fallback:** the MIT [soulseek-rs](https://github.com/michel/soulseek-rs) (v19.1.0, commit `dc39e24`) compiled for iOS arm64 and bridged with UniFFI or `swift-bridge`.
- **[builder]** Decide in spike S4 after a security read of SeeleseekCore against the hardening list below. Whichever core is chosen gets all of that hardening.
- Ideas worth reusing from the fork:
  - peer-admission grace, so newly connected peers aren't dropped before they reply
  - incremental draining of search results
  - optional queue-length parsing

**Protocol rules** (from the Nicotine+ protocol documentation):
- Each client reserves its own major version number; 177 is for experimental clients. pointFlac uses 177 in development and asks the Soulseek admins for its own number before any wider release.
- Honour the server's excluded-search-phrases list.
- No randomly generated usernames.
- Extending the protocol needs admin approval.

**Required hardening** (findings from reviewing the fork's library):
- Cap every frame size on peer and server connections. Control frames get a small cap; folder listings get a bounded size. A peer must not be able to make the app buffer 4 GiB.
- Never accept a peer-claimed file size larger than the size requested from search or browse; abort the transfer instead.
- Fix the `message_size + 4` overflow, even though iOS is 64-bit only.
- Keep zlib inflate caps (16 MiB / 32 MiB, as the fork did).
- Treat peer usernames as unauthenticated. Downloaded bytes are trusted only after validation (§5.3) and the size check.
- Local filenames are built only from sanitised base names inside a per-transfer staging folder; remote paths never become local paths.
- Fuzz the message parsers as part of the test suite (Swift fuzzing for SeeleseekCore, or `cargo fuzz` for the Rust fallback).

**Behaviour:**
- Search, browse a folder, download, pause, resume and cancel.
- No shares are announced (zero shared files).
- Participates in the distributed network as a leaf only, if the core requires it.
- Connections run only while foregrounded or playing.

**Client identifier:** use an experimental client version for development. **[builder]** Register an appropriate identifier before any wider release.

**Build flag:**
- A compile-time option (e.g. a `SOULSEEK` flag or a separate scheme or target) controls inclusion. Builds without it contain no Soulseek code.
- CI builds and tests both variants.

### 5.7 The signal readout

`SignalState` contains:
- source file format: depth, rate, channels
- the processing chain state: Pure, or the list of active blocks
- the format pointFlac hands to iOS
- the current hardware sample rate as reported by iOS
- whether pointFlac resampled (from → to)
- the output port type and name (USB, wired, Bluetooth, built-in)

The strip shows `FLAC · <depth> · <DAC rate> · <signal>`. The `<signal>` value is one of:

| Value | When |
|---|---|
| **● Pure** | No processing by pointFlac, and the hardware rate equals the file rate. |
| **● Resampled 96→48** | pointFlac had to change the rate. |
| **● Processing** | One or more DSP blocks are active. Tapping it opens the chain. |
| **● Scrubbing** | A finger is on the record. |
| **● 32→24-bit** | pointFlac reduced the bit depth with dither, because the path or device can't take the file's depth. |
| **● Volume 80%** (shown next to the state) | The system volume is below 100% on a USB route. A tip explains why that may break bit-perfect output. |
| **● Bluetooth (lossy)** | The route is Bluetooth. The readout says so plainly: iOS re-encodes for Bluetooth, so nothing is lossless. |

Further rules:
- The words **"bit-perfect"** are only shown for route and device combinations that pointFlac has *verified*. In v1 that means none until hardware testing (§6.6) confirms one. Until then, the strongest claim is **"Untouched by pointFlac"**.
- Tapping the strip opens a details sheet with every field above and plain-language explanations, including volume advice.

### 5.8 Privacy and security

- No analytics, crash-reporting SDKs or trackers.
  - **[call]** Crash logs come only from Apple's on-device diagnostics, which the user can share manually.
- Network traffic goes only to: archive.org, the Soulseek server and its peers (module builds only), and artwork lookups.
  - **[call]** Artwork lookups use MusicBrainz and Cover Art Archive, are opt-in, and send only artist and album names.
  - **[call, ruling R26]** MusicBrainz name lookups for search suggestions are on by default and disclosed: Get Music notes under its search field that what you type is sent to musicbrainz.org, and Settings → "Look up names online (MusicBrainz)" turns them off at once.
- Secrets live only in the Keychain (Soulseek credentials), as `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they are never synced or backed up.
- All networking uses TLS where the service supports it. Soulseek's lack of encryption is disclosed in the UI.
- All untrusted input has explicit limits:
  - file sizes, metadata block sizes and image sizes
  - JSON response sizes from Archive
  - Soulseek frames
- Logging uses `os.Logger` with privacy annotations. It never logs credentials or message contents.

---

## 6. Testing strategy

Testing must be thorough. It gates every change.

### 6.1 Fixtures

A script generates a fixture set with the `flac` command-line tool:
- 16, 24 and 32-bit
- 44.1, 48, 88.2, 96, 176.4, 192 and 384 kHz
- mono and stereo
- odd block sizes, files without seek tables, files without MD5
- ID3-prefixed FLAC
- truncated files, a renamed MP3, a corrupt STREAMINFO, a corrupt frame CRC
- multichannel files

Fixtures with known sample patterns (ramps, every bit toggling, full-scale and lowest-bit signals) let bit-exactness be proven.

### 6.2 Unit tests

- **`PFFlac`:** every fixture decodes to the expected samples, the admission rule accepts and rejects the right files, MD5 verification works, and seeking is sample-accurate.
- **`PFDSP`:**
  - Filter frequency response at 44.1, 96 and 192 kHz against analytic values.
  - Automatic headroom never lets the output exceed full scale.
  - The limiter holds its true-peak ceiling.
  - EBU R128 loudness against the EBU Tech 3341/3342 test vectors.
  - Crossfeed against reference responses.
  - Resampler quality: passband ripple, stop-band rejection, THD+N.
  - Pure mode is bit-identical.
- **`PFCore`:** side splitting (the cases from Runout's tests, plus the fixed short-album rule) and needle-position mapping.
- **`PFSearch`:** ranking golden tests (accents, punctuation, typos, prefixes), and incremental update correctness.
- **`PFLibrary` / `PFDownloads`:** the publication pipeline, including interrupted and failed steps, retry, and the rule that cancellation never deletes published music. Uses a fake file system and providers.
- **`PFArchive`:** recorded API responses, FLAC-only file selection, and the Friday Drops determinism.
- **`PFSoulseek`:**
  - The chosen core's own tests.
  - A local fake server and peers, as in the fork, covering search, browse and download.
  - Hostile-peer tests: oversized frames, a size larger than requested, malformed messages.
  - Fuzz smoke runs on the message parsers.

### 6.3 Bit-exact pipeline tests

For every depth and rate fixture:
1. Run the real `PFAudio` output path in a test harness. **[builder]** Use offline or manual rendering, or a capture at the output unit's input.
2. Assert that the bytes handed to iOS equal the decoded source exactly, in Pure mode.

Also assert gapless joins: no inserted or dropped samples at track boundaries.

### 6.4 UI tests

XCUITest flows on the simulator:
- first run
- import from Files
- play a record
- the crate → deck hand-off
- tonearm seek, platter scrub and side flip
- Deck ↔ Cover switch
- search with filters
- Internet Archive download (stubbed network)
- the Downloads list
- turning on Sound blocks and Pure
- the empty and error states

Snapshot tests cover key screens in light, dark and large text.

### 6.5 Performance tests

The §8 budgets are enforced as automated tests where the platform allows:
- launch time
- search latency at 10k and 100k synthetic tracks
- hitch ratio while flicking the crate and during the hand-off animation, measured with signposts
- time from needle drop to first sound
- memory ceiling during artwork-heavy browsing

Budgets are enforced on device or simulator runs. CI uses tolerances because shared runners are noisy.

### 6.6 On-device checklist

Run before each release, on Kiran's iPhone:
- **EarPods:** 44.1 and 48 kHz switching, and 96 kHz files showing "Resampled 96→48".
- Route changes and unplugging, calls and other interruptions, background playback and lock-screen controls.
- iCloud files that haven't been downloaded.
- **When a USB DAC is available:** sample-rate following, checked on the DAC's indicator.
- **When a bit-test-capable DAC is available** (e.g. RME ADI-2): run the bit-test files at 16, 24 and 32 bit. Only then can "bit-perfect" be enabled for that route.

### 6.7 CI

- GitHub Actions on macOS runners, which are free for public repos. On every push and PR:
  - build both variants (with and without Soulseek)
  - unit, pipeline, UI and snapshot tests on the simulator
  - the Soulseek core's tests (plus Rust tests and clippy if the fallback is used) and a fuzz smoke run
  - SwiftLint / SwiftFormat checks
- Performance suite: run nightly or on demand.
- Releases build an unsigned `.ipa` for sideloading, with Soulseek included. When TestFlight arrives, the TestFlight and App Store builds use the variant without Soulseek.

---

## 7. Repository, workflow and release

- **Repo:** `github.com/kiraa06/pointFlac`, **public**, MIT. Created only after this design is approved.
- **Local checkout:** `~/Documents/Echocore/` today. The repo is created there or the folder renamed **[builder: confirm with Kiran]**. `.superpowers/` goes in `.gitignore`.
- **Bundle ID [call]:** `io.github.kiraa06.pointflac`.
- **Git identity:** all commits use `Kiran P Jose <kiran.p.jose02@gmail.com>`, set repo-locally before the first commit. Kiran's global config is his work email.
- **Commit messages:** Conventional Commits (`feat(audio): …`, `fix(search): …`).
  - No Jira keys. This is Kiran's personal GitHub, and he said any convention is fine; his work-repo rule about Jira prefixes doesn't apply here.
- **Working agreement:** each commit and each push needs Kiran's explicit approval at the time. No standing permission.
- **README:**
  - what pointFlac is, with screenshots
  - sideloading instructions (AltStore, SideStore, Sideloadly) with the 7-day refresh explained
  - build-from-source steps
  - the licence list
  - later, the TestFlight link
- **Docs:** `docs/` holds this design, an architecture map, a testing guide and the on-device checklist. A plain-language CHANGELOG lists what changed in each release.
- **Third-party notices** are bundled in-app (Settings → About → Licences) and in the repo.

---

## 8. Performance budgets

Kiran's top anti-goal is slowness. These numbers are hard requirements and are tested (§6.5).

| Interaction | Budget |
|---|---|
| Cold launch → usable player | < 0.5 s on iPhone 17 Pro (warm launch < 0.25 s) |
| Keystroke → local results on screen | < 8 ms of work (one frame at 120 Hz) at 100k tracks |
| Crate flick, shelf scroll, hand-off animation, disc spin | 0 dropped frames at 120 Hz (hitch ratio < 1 ms/s) |
| Needle drop or play → first audible sample | < 150 ms for local files |
| Seek (tonearm release) → audio at new position | < 50 ms |
| Deck ↔ Cover switch | Starts within 1 frame; animation never stutters |
| Importing or validating 10k files | Background only; the UI keeps its frame budget throughout |
| Memory while browsing 1,000 albums of artwork | Bounded cache (default ≤ 150 MB of decoded images; **[builder]** tune) |

---

## 9. What Kiran decided

- iOS first; Mac later.
- New project and new public repo on his own GitHub. The app is named **pointFlac**.
- Unfiltered 24- and 32-bit playback, with 32-bit integer decoded "to near perfection" and the full 32-bit path with a USB DAC dongle and IEMs.
- **FLAC downloads in the app, like the fork:** Soulseek and Internet Archive. Soulseek can be turned off; local FLAC loading works in every build.
- Sideloading for now, TestFlight later, the App Store eventually.
- No public sharing or friends in v1.
- The look combines **Glass Turntable (Deck)** and **Editorial Modern (Cover)**, with a switch between them.
- The Deck is interactive with precision: tonearm, platter and a shelf for selecting and searching albums.
- A very smooth crate → deck animation at the 3× slow-motion pace.
- Search: artist or album names, with results instantly as he types.
- The public GitHub release and the public repo include Soulseek.
- Play carries on automatically from side to side.
- Commit conventions are free; no Jira keys.
- Test device: iPhone 17 Pro on the latest iOS beta.
- Both views follow light/dark mode, so there are four looks.
- A full professional sound section (EQ, headphone correction, volume levelling, warmth and more), modelled on open-source work.
- Slowness is the one thing that must never happen.

---

## 10. Risks and spikes (do these first)

| ID | Spike | Why | Pass criteria |
|---|---|---|---|
| S1 | Output path for bit-perfect | Everything rests on reproducing Onkyo's result. | Bit-exact pipeline test passes for 16, 24 and 32-bit, with a documented API choice. Hardware confirmation follows when a capable DAC is available. |
| S2 | libFLAC on iOS | A 32-bit decode dependency. | libFLAC ≥ 1.4 builds as an XCFramework or Swift package for iOS device and simulator, and decodes every fixture correctly. |
| S3 | Rate negotiation behaviour | iOS treats the preferred rate as a hint. | Documented behaviour for EarPods, the built-in speaker and the simulator; the app reads back the real rate and reacts. |
| S4 | Soulseek core choice | The Soulseek module's foundation. | SeeleseekCore (or the soulseek-rs fallback) builds for iOS device and simulator, passes a security read against §5.6's hardening list, and completes a local fake-peer search, browse and download. |
| S5 | Search at 100k | The anti-goal is slowness. | The in-memory index (or FTS5) meets the < 8 ms keystroke budget on a recent iPhone. |
| S6 | Hand-off animation at 120 Hz | The signature moment. | Zero hitches in Instruments over 50 runs with real artwork. |

Other risks:
- Apple may tighten sideloading.
- AutoEq data licensing may rule out a bundled headphone list.
- Soulseek peers may refuse downloads to non-sharing users.
- iCloud files may be slow to download on demand.

---

## 11. Library survey (§11 references)

Surveyed on 2026-10-20. Licences were checked against each project's repository.

| Area | Use | Licence | Notes |
|---|---|---|---|
| [libFLAC](https://github.com/xiph/flac) 1.5.0 | **Link** | BSD-3 | 32-bit since 1.4.0. Build an XCFramework with `WITH_OGG=OFF`, or use sbooth's [flac-binary-xcframework](https://github.com/sbooth/flac-binary-xcframework), which needs Ogg. The `flac` command-line tools are GPL; they are used only to *generate test fixtures*, not shipped. |
| [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine) | Reference / borrow | MIT | As shipped it pulls in LGPL libraries; borrow code, don't adopt the package. |
| [AudioStreaming](https://github.com/dimitris-c/AudioStreaming) | Reference | MIT | AVAudioEngine gapless queueing. |
| [AudioKit](https://github.com/AudioKit/AudioKit) | Reference | MIT | Synthesis-oriented; its file playback relies on Apple's FLAC decoder. |
| [Cog](https://github.com/losnoco/Cog) | Reference only | **GPL-2.0** | Its iOS output is RemoteIO Float32 and resamples everything to the session's rate. |
| [RBJ Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) | Implement | W3C Note | Biquads in double precision. |
| [libebur128](https://github.com/jiixyj/libebur128) | **Link** | MIT | EBU R128 loudness, true peak, loudness range. |
| [libbs2b](https://bs2b.sourceforge.net/license.html) | **Link / port** | MIT | Crossfeed; tiny. |
| [r8brain-free-src](https://github.com/avaneev/r8brain-free-src) | **Link** (resampler candidate) | MIT | Asks for a credit line. The alternative is Apple's `AVAudioConverter` at mastering quality. |
| speexdsp resampler | Candidate | BSD-3 | — |
| libsoxr | Avoid | **LGPL** | Static linking on iOS conflicts with LGPL's relink requirement. |
| [AutoEq](https://github.com/jaakkopasanen/AutoEq) | Algorithm ideas / file format | Code MIT; **results unlicensed** | Don't bundle its results. |
| [OPRA](https://github.com/opra-project/OPRA) | **Bundle** | CC BY-SA 4.0 | Requires attribution: the logo and each preset author. |
| [GRDB.swift](https://github.com/groue/GRDB.swift) 7.x | **Link** | MIT | Its package manifest enables FTS5. |
| [SymSpell](https://github.com/wolfgarbe/SymSpell) / [SymSpellSwift](https://github.com/gdetari/SymSpellSwift) | Candidate | MIT | Pin to the MIT repositories. |
| [seeleseek](https://github.com/bretth18/seeleseek) `SeeleseekCore` | **Soulseek core (first choice)** | MIT | Swift 6, Network.framework, iOS 18. |
| [soulseek-rs](https://github.com/michel/soulseek-rs) 19.1.0 | Soulseek core (fallback) | MIT | Rust; needs a Swift bridge and the hardening in §5.6. |
| Soulseek.NET, slskd, Nicotine+, aioslsk, Seeker | Reference only | **GPL-3 / AGPL-3** | Protocol behaviour only. |
| [Nicotine+ protocol documentation](https://nicotine-plus.org/doc/SLSKPROTOCOL.html) | Reference | — | Version numbers, login, server rules. |
| Internet Archive [scrape](https://doc-tools.readthedocs.io/en/ia-test-gsod/item-search-apis.html) and [metadata](https://archive.org/developers/md-read.html) APIs | Use | — | Follow the [bot guidance](https://archive.org/developers/bots.html): a descriptive User-Agent; honour 429 and `Retry-After`; at most about 4 parallel downloads. |
| Inter, Silkscreen fonts | Bundle | SIL OFL 1.1 | — |

**Licence red flags:**
- No GPL, LGPL or AGPL code may be linked; those projects are reading material only.
- OPRA attribution must appear in the UI.
- r8brain asks for a credit line.
- Pin SymSpell to its MIT repositories.

**Evidence on bit-perfect output on iOS:**
- [RME forum thread](https://forum.rme-audio.de/viewtopic.php?id=40649): Onkyo HF Player passes 16, 24 and 32-bit on iOS 18.1.1; Neutron and Apple Music fail.
- [AudioScienceReview](https://www.audiosciencereview.com/forum/index.php?threads/iphone-usb-dacs-any-good-bit-perfect-hd.9935/): a bit-perfect pass up to 24/96.
- [Vox forum](https://vox.rocks/forum/t/bit-rate-of-vox-player-when-external-dac-connected/3839): there's no API for a DAC's bit depth.
- [Apple QA1631](https://developer.apple.com/library/ios/qa/qa1631/_index.html): audio session preferences are hints.
