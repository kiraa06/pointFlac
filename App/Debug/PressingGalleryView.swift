#if DEBUG
    import PFDesign
    import SwiftUI

    /// The playlist pressings, every way they are drawn, for checking the art (Plan 11, Task B): Favourites on the real
    /// Glasshouse deck, the shelf strip's discs, the square cover mosaics, and each example as a deck-size record on
    /// the platter with its disc and mosaic beside it. The eight examples are built from the fixture albums, repeated
    /// where one needs six covers.
    ///
    /// `-PFPressingGallery -PFPreloadFixtures` opens it over the app; `-PFGalleryAnchor <id>` scrolls it to a section
    /// (`deck`, `strip`, `covers`, `record-0` … `record-7`) for screenshots, and `-PFGallerySpin YES` turns the records
    /// at 33⅓.
    struct PressingGalleryView: View {
        let model: AppModel
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isMonochrome) private var mono
        @Environment(\.dynamicTypeSize) private var typeSize
        @State private var spinning = UserDefaults.standard.bool(forKey: "PFGallerySpin")

        static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-PFPressingGallery") }

        var body: some View {
            let theme = Theme.look(stage: .deck, dark: scheme == .dark, monochrome: mono)
            let looks = Self.examples(model.library.albums.map(\.id))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        header
                        section("On the deck", id: "deck") {
                            GalleryDeck(look: looks[0], spinning: spinning)
                        }
                        section("Shelf strip", id: "strip") { strip(looks, theme: theme) }
                        section("Cover mosaics", id: "covers") { mosaics(looks) }
                        ForEach(Array(looks.enumerated()), id: \.offset) { index, look in
                            GalleryRecord(look: look, spinning: spinning)
                                .id("record-\(index)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 24)
                }
                .onAppear {
                    guard let anchor = UserDefaults.standard.string(forKey: "PFGalleryAnchor") else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            .background(theme.background.ignoresSafeArea())
            .foregroundStyle(theme.ink)
            .accessibilityIdentifier("pressingGallery")
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pressings").font(.largeTitle.bold())
                Text("Playlists as custom-pressed records. Debug gallery.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Toggle("Turn at 33⅓", isOn: $spinning)
                    .font(.subheadline)
                    .padding(.top, 6)
            }
        }

        private func section<Content: View>(_ title: String, id: String, @ViewBuilder content: () -> Content)
            -> some View
        {
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased())
                    .font(.footnote.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                content()
            }
            .id(id)
        }

        /// The shelf's Playlists strip as the spec draws it: each disc with its name in `.caption`, one line (two at
        /// accessibility sizes), and its count in `.caption2`.
        private func strip(_ looks: [PressingLook], theme: Theme) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
                        VStack(spacing: 6) {
                            PressingDisc(look: look, size: 60)
                            VStack(spacing: 1) {
                                Text(look.title)
                                    .font(.caption)
                                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                                    .minimumScaleFactor(typeSize.isAccessibilitySize ? 0.7 : 1)
                                    .multilineTextAlignment(.center)
                                Text(look.songCount == 1 ? "1 song" : "\(look.songCount) songs")
                                    .font(.caption2)
                                    .foregroundStyle(theme.inkSecondary)
                            }
                            .frame(width: typeSize.isAccessibilitySize ? 150 : 72)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(look.title), playlist, \(look.songCount) songs")
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }

        private func mosaics(_ looks: [PressingLook]) -> some View {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(Array(looks.enumerated()), id: \.offset) { _, look in
                    PressingCoverMosaic(look: look)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                }
            }
        }

        /// The mockup's eight examples, built from the fixture albums' IDs (or made-up ones before the fixtures load:
        /// the art then shows generated sleeves, as it would anyway). The mockup draws on ten albums; the five
        /// fixtures stand in for them in turn, so some labels repeat a cover.
        static func examples(_ ids: [String]) -> [PressingLook] {
            let pool = ids.isEmpty ? ["a", "b", "c", "d", "e"] : ids
            func pick(_ indices: [Int]) -> [String] { indices.map { pool[$0 % pool.count] } }
            return [
                PressingLook(
                    title: "Favourites", colour: .ruby, coverAlbumIDs: pick([6, 3, 0, 1, 5, 9]), songCount: 24,
                    isFavourites: true, id: "favourites"),
                PressingLook(
                    title: "Late Night Drives", colour: .amber, coverAlbumIDs: pick([2, 9, 1]), songCount: 6,
                    isFavourites: false, id: "7c3e9b1a-52d0-4f8e-a1c2-9e7d3b5f0a14"),
                PressingLook(
                    title: "Gym", colour: .jade, coverAlbumIDs: pick([5]), songCount: 9, isFavourites: false,
                    id: "e41b07c2-9d3a-4b61-8f2e-0c5a7d913e88"),
                PressingLook(
                    title: "Rainy Sunday", colour: .ocean, coverAlbumIDs: pick([3, 4]), songCount: 14,
                    isFavourites: false, id: "2a9d6f30-1b7c-4e2a-9a55-6c0e8f2b4d17"),
                PressingLook(
                    title: "Focus", colour: .violet, coverAlbumIDs: pick([4, 8, 5, 7]), songCount: 31,
                    isFavourites: false, id: "b6f04e8d-7a21-4c39-b0d6-3e9f1a52c7b0"),
                PressingLook(
                    title: "Road Trip 2026", colour: .citrine, coverAlbumIDs: pick([0, 2, 7, 6, 4]), songCount: 48,
                    isFavourites: false, id: "91c5a2e7-3f68-4d0b-a7c4-58e2b6d9f031"),
                PressingLook(
                    title: "Demos", colour: .smoke, coverAlbumIDs: [], songCount: 0, isFavourites: false,
                    id: "d03a8c51-6e2f-47b9-8d10-f4a7c2e95b36"),
                PressingLook(
                    title: "Vault", colour: .onyx, coverAlbumIDs: pick([8, 7, 9, 2, 3, 0]), songCount: 17,
                    isFavourites: false, id: "5e7f1d94-c0b3-4a8e-9f62-1d8b3a7e0c45"),
            ]
        }
    }

    /// The deck's record diameter on a 402-point phone, as the player draws it.
    @MainActor private var deckRecordDiameter: CGFloat { DeckLayout(size: DeckPreview.reference).recordRadius * 2 }

    /// Side A's track gaps for an example: half its songs, a little uneven, as a real side's would be.
    private func galleryBands(_ look: PressingLook) -> [CGFloat] {
        let tracks = max(1, (look.songCount + 1) / 2)
        let outer = VinylGeometry.outerGrooveToRecord
        let inner = VinylGeometry.innerGrooveToRecord
        var random = SeededRandom(look.id)
        return (1..<max(tracks, 2)).compactMap { i in
            guard tracks > 1 else { return nil }
            let at = (Double(i) + random.range(-0.25, 0.25)) / Double(tracks)
            return outer - (outer - inner) * at
        }
    }

    /// The angle a record turned at 33⅓ shows at `date`, or a fixed one when still.
    private func recordAngle(_ date: Date, spinning: Bool) -> Double {
        spinning ? (date.timeIntervalSinceReferenceDate * 200).truncatingRemainder(dividingBy: 360) : 0
    }

    /// One example as the deck plays it: the deck-size record on Glasshouse's smoked platter, with its shelf disc,
    /// its cover mosaic and the words it prints.
    private struct GalleryRecord: View {
        let look: PressingLook
        let spinning: Bool
        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                let titles =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                titles {
                    Text(look.title).font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(look.colour.name).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
                ZStack {
                    GalleryPlatter(diameter: deckRecordDiameter * VinylGeometry.platterToRecord)
                    TimelineView(.animation(paused: !spinning)) { timeline in
                        RecordView(
                            face: RecordFace(pressing: look, side: "A", bands: galleryBands(look)),
                            diameter: deckRecordDiameter, angle: recordAngle(timeline.date, spinning: spinning))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                let layout =
                    typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
                layout { pieces }
            }
        }

        @ViewBuilder private var pieces: some View {
            PressingDisc(look: look, size: 60)
            PressingCoverMosaic(look: look)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(look.displayText)
                Text(look.matrix(side: "A"))
                Text(look.monogram.isEmpty || look.isFavourites ? "♥" : look.monogram)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Glasshouse's smoked platter, simply: a turned dark disc a little wider than the record, so the coloured vinyl
    /// is seen over what it will lie on.
    private struct GalleryPlatter: View {
        let diameter: CGFloat
        @Environment(\.isMonochrome) private var mono

        var body: some View {
            let tones = DeckColors(monochrome: mono, dark: false)
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            tones(0x2F333A), tones(0x4D535C), tones(0x2F333A), tones(0x181A1F), tones(0x2F333A),
                            tones(0x4D535C), tones(0x2F333A), tones(0x181A1F), tones(0x2F333A),
                        ], center: .center, angle: .degrees(189))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
        }
    }

    /// Favourites on the real Glasshouse deck, laid out at the player's size: the same layers the player draws, with
    /// the needle a little way into side A and the display showing the pressing's idle line.
    private struct GalleryDeck: View {
        let look: PressingLook
        let spinning: Bool
        @Environment(\.isMonochrome) private var mono
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let reference = DeckPreview.reference
            let design = DeckDesign.standard
            let paint = DeckPaint(
                design: design, theme: Theme.look(stage: .deck, dark: scheme == .dark, monochrome: mono))
            let layout = DeckLayout(size: reference, design: design)
            // At the player's own size, never scaled: a resampled groove field shimmers.
            Group {
                DeckLayers(paint: paint, layout: layout, live: false, playing: true) {
                    DeckMovingParts(
                        paint: paint, layout: layout, strobePhase: 0,
                        armPosition: layout.travel.position(forFraction: 0.12), lift: 0
                    ) {
                        TimelineView(.animation(paused: !spinning)) { timeline in
                            RecordView(
                                face: RecordFace(pressing: look, side: "A", bands: galleryBands(look)),
                                diameter: layout.recordRadius * 2,
                                angle: recordAngle(timeline.date, spinning: spinning))
                        }
                        .frame(width: layout.recordRadius * 2, height: layout.recordRadius * 2)
                        .position(layout.recordCenter)
                    }
                } front: {
                    let screen = DeckScreen.frame(in: layout.size)
                    DeckDisplay(lines: [look.displayText, "CUE A1  33⅓"], paint: paint)
                        .frame(width: screen.width, height: screen.height)
                        .position(x: screen.midX, y: screen.midY)
                }
                .frame(width: layout.size.width, height: layout.size.height)
            }
            .frame(maxWidth: .infinity)
        }
    }
#endif
