import PFDesign
import SwiftUI
import UniformTypeIdentifiers

/// The Shelf (spec §4.6): search at the top, the filter chips, the crate, and the results under it. Local results
/// update on every keystroke; the search runs in `onChange`, never in `body`, and the field shows how long it took.
/// Tapping the front sleeve starts the hand-off; holding a sleeve or a result offers Play Next and Add to Up Next.
struct ShelfPanel: View {
    let library: any LibraryBrowsing
    /// For the online results that stream in under the local ones (spec §4.6).
    let finder: any MusicFinding
    let playback: PlaybackController
    let theme: Theme
    let close: () -> Void
    let getMusic: () -> Void
    /// An album (or a song on it) was picked, with the front sleeve's frame in the player's space for the hand-off.
    let pick: (AlbumCard, TrackRow.ID?, CGRect?) -> Void

    @State private var query = ""
    @State private var filter: SearchFilter = .all
    @State private var results = SearchResults(albums: [], tracks: [], elapsedMilliseconds: 0)
    @State private var front: AlbumCard.ID?
    @State private var crateFrame: CGRect = .zero
    @State private var importing = false
    @State private var importNote: String?
    /// Online results by provider name, for the current phrase.
    @State private var online: [(provider: String, rows: [RemoteResultRow])] = []
    /// Search was pressed for the current phrase.
    @State private var immediate = false
    @FocusState private var searching: Bool

    /// The front sleeve's size: smaller while typing, so the results stay above the keyboard.
    private var sleeve: CGFloat { searching && !query.isEmpty ? 96 : 150 }
    private static let flac = UTType(filenameExtension: "flac") ?? .audio

    private var crateAlbums: [AlbumCard] {
        query.isEmpty && filter == .all ? library.albums : results.albums
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(theme.inkSecondary.opacity(0.4)).frame(width: 38, height: 5)
                .padding(.top, 8).padding(.bottom, 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height > 40 { close() } })
                .accessibilityLabel("Close the shelf")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { close() }
            searchField
            chips
            ScrollView {
                VStack(spacing: 0) {
                    crate
                    caption
                    resultsList
                    footer
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(theme.isDark ? Color(white: 0.1).opacity(0.985) : Color(white: 0.99).opacity(0.985))
                .shadow(color: .black.opacity(0.2), radius: 20, y: -8)
                .ignoresSafeArea(edges: .bottom)
        }
        .foregroundStyle(theme.ink)
        .onChange(of: query, initial: true) { runSearch() }
        .onChange(of: filter) { runSearch() }
        .onChange(of: library.albums) { runSearch() }
        // Keyed by the phrase and by Search: a new phrase cancels the old search. Online search runs on Search only,
        // never on a typing pause: one Internet Archive search costs about 21 requests, and Soulseek rate-limits
        // accounts that search often (integration ruling).
        .task(id: "\(immediate)|\(query)") {
            if immediate { await searchOnline(after: .zero) } else { online = [] }
        }
        .onSubmit { immediate = true }
        .onChange(of: query) { immediate = false }
        .fileImporter(isPresented: $importing, allowedContentTypes: [Self.flac], allowsMultipleSelection: true) {
            result in
            switch result {
            case .success(let urls):
                Task {
                    let outcome = await library.importFiles(urls)
                    importNote =
                        "\(outcome.added) added" + (outcome.rejected.isEmpty ? "" : ", not added: ")
                        + outcome.rejected.joined(separator: "; ")
                    runSearch()
                }
            case .failure(let error):
                importNote = "The picker failed: \(error.localizedDescription)"
            }
        }
    }

    private func runSearch() {
        results = library.search(query, filter: filter)
        if front == nil || !crateAlbums.contains(where: { $0.id == front }) {
            front = crateAlbums.first?.id
        }
    }

    // MARK: Search and chips

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.inkSecondary)
            TextField("Search your shelf", text: $query)
                .focused($searching)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("shelfSearch")
            if !query.isEmpty {
                Text(String(format: "%.1f ms", results.elapsedMilliseconds))
                    .font(Typeface.monoSmall).foregroundStyle(theme.inkSecondary)
                    .accessibilityIdentifier("searchTiming")
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.inkSecondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.hairline.opacity(0.5)))
        .padding(.horizontal, 16)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SearchFilter.allCases, id: \.self) { chip in
                    Button {
                        filter = chip
                    } label: {
                        Text(chip.label)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(filter == chip ? theme.ink : theme.hairline.opacity(0.6)))
                            .foregroundStyle(filter == chip ? theme.background : theme.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chip-\(chip.key)")
                    .accessibilityAddTraits(filter == chip ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    // MARK: The crate

    private var crate: some View {
        let albums = crateAlbums
        let frontIndex = albums.firstIndex { $0.id == front } ?? 0
        let sleeve = sleeve
        return GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: -sleeve * 0.28) {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                        Sleeve(album: album)
                            .frame(width: sleeve, height: sleeve)
                            .visualEffect { content, geometry in
                                let width = geometry.bounds(of: .scrollView(axis: .horizontal))?.width ?? 400
                                let mid = geometry.frame(in: .scrollView(axis: .horizontal)).midX
                                let d = (mid - width / 2) / sleeve
                                let clamped = min(max(d, -2.5), 2.5)
                                return
                                    content
                                    .rotation3DEffect(
                                        .degrees(-Double(min(max(clamped * 70, -55), 55))), axis: (x: 0, y: 1, z: 0),
                                        perspective: 0.5
                                    )
                                    .scaleEffect(1 - abs(clamped) * 0.07)
                                    .opacity(1 - max(0, abs(clamped) - 1.6) * 0.6)
                            }
                            .zIndex(-Double(abs(index - frontIndex)))
                            .onTapGesture {
                                if album.id == front {
                                    pick(album, nil, frontRect)
                                } else {
                                    withAnimation(.spring(duration: 0.4)) { front = album.id }
                                }
                            }
                            .contextMenu { upNextMenu(album) }
                            .accessibilityElement()
                            .accessibilityLabel("\(album.title), \(album.artist)")
                            .accessibilityHint(
                                album.id == front ? "Puts the record on the deck" : "Brings it to the front"
                            )
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("sleeve-\(index)")
                            .id(album.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, (proxy.size.width - sleeve) / 2, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $front, anchor: .center)
            .sensoryFeedback(.selection, trigger: front)
        }
        .frame(height: sleeve + 24)
        .animation(.spring(duration: 0.35), value: sleeve)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(PlayerSpace.name))
        } action: {
            crateFrame = $0
        }
        .overlay {
            if albums.isEmpty {
                VStack(spacing: 10) {
                    Text(query.isEmpty ? "Your shelf is empty" : "No records match")
                        .font(.headline)
                    if query.isEmpty {
                        Button("Add music", systemImage: "plus") { getMusic() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        }
    }

    /// The front sleeve's frame, from the crate's: it always sits centred.
    private var frontRect: CGRect? {
        guard crateFrame != .zero else { return nil }
        return CGRect(
            x: crateFrame.midX - sleeve / 2, y: crateFrame.midY - sleeve / 2, width: sleeve,
            height: sleeve)
    }

    @ViewBuilder
    private var caption: some View {
        let albums = crateAlbums
        if let index = albums.firstIndex(where: { $0.id == front }) {
            let album = albums[index]
            VStack(spacing: 3) {
                Text(album.title).font(.headline)
                Text(captionLine(album, index: index, of: albums.count))
                    .font(.footnote).foregroundStyle(theme.inkSecondary)
                    .accessibilityIdentifier("crateCaption")
            }
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }

    private func captionLine(_ album: AlbumCard, index: Int, of count: Int) -> String {
        var parts = [album.artist]
        if let year = album.year { parts.append(String(year)) }
        parts.append(album.bestFormat)
        parts.append("\(index + 1) of \(count)")
        return parts.joined(separator: " · ")
    }

    // MARK: Results

    @ViewBuilder
    private var resultsList: some View {
        if !query.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !results.albums.isEmpty, filter != .songs {
                    header("Albums")
                    ForEach(results.albums) { album in
                        Button {
                            front = album.id
                            pick(album, nil, frontRect)
                        } label: {
                            resultRow(
                                art: album, title: "\(album.artist) · \(album.title)",
                                detail: "Album · \(album.trackCount) tracks", quality: album.bestFormat)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { upNextMenu(album) }
                        .accessibilityIdentifier("result-album-\(album.title)")
                    }
                }
                if !results.tracks.isEmpty {
                    header("Songs")
                    ForEach(results.tracks) { track in
                        Button {
                            if let album = albumOf(track) {
                                front = album.id
                                pick(album, track.id, frontRect)
                            }
                        } label: {
                            resultRow(
                                art: albumOf(track), title: "\(track.artist) · \(track.title)",
                                detail: "Song · \(track.album)" + (track.side.map { " · \($0)" } ?? ""),
                                quality: track.format)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let album = albumOf(track) { upNextMenu(album, from: track.id) }
                        }
                        .accessibilityIdentifier("result-track-\(track.title)")
                    }
                }
                ForEach(online, id: \.provider) { group in
                    header("Online · \(group.provider)")
                    ForEach(group.rows) { row in
                        onlineRow(row)
                    }
                }
                if results.albums.isEmpty, results.tracks.isEmpty, online.isEmpty {
                    Text("Nothing on your shelf matches. Try Get Music to look online.")
                        .font(.footnote).foregroundStyle(theme.inkSecondary).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Online search runs on Search, with at least 3 characters. A new phrase cancels the old one: this runs in a
    /// task keyed by the query.
    private func searchOnline(after pause: Duration) async {
        online = []
        let phrase = query.trimmingCharacters(in: .whitespaces)
        guard phrase.count >= 3 else { return }
        try? await Task.sleep(for: pause)
        guard !Task.isCancelled, phrase == query.trimmingCharacters(in: .whitespaces) else { return }
        for provider in finder.providers {
            for await batch in finder.search(phrase, provider: provider.id) {
                guard !Task.isCancelled else { return }
                if let index = online.firstIndex(where: { $0.provider == provider.name }) {
                    online[index].rows = batch
                } else {
                    online.append((provider.name, batch))
                }
            }
        }
    }

    private func onlineRow(_ row: RemoteResultRow) -> some View {
        let queued = finder.downloads.contains { $0.id == row.id }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(row.title)).font(.subheadline).lineLimit(1)
                Text(row.subtitle).font(.caption).foregroundStyle(theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(row.format.replacingOccurrences(of: "FLAC ", with: "")) · \(row.sizeText)")
                .font(Typeface.monoSmall).foregroundStyle(theme.inkSecondary)
            Button {
                finder.download(row)
            } label: {
                Image(systemName: queued ? "checkmark.circle.fill" : "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .disabled(queued)
            .accessibilityLabel(queued ? "Queued" : "Download \(row.title)")
            .accessibilityIdentifier("shelfDownload-\(row.id)")
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline.opacity(0.6)).frame(height: 0.5) }
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased()).font(Typeface.cellLabel).tracking(1.2).foregroundStyle(theme.inkSecondary)
            .padding(.top, 10).padding(.bottom, 4)
    }

    private func resultRow(art: AlbumCard?, title: String, detail: String, quality: String) -> some View {
        HStack(spacing: 10) {
            ArtworkView(albumID: art?.id ?? title, artwork: art?.artwork)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(title)).font(.subheadline).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(quality.replacingOccurrences(of: "FLAC ", with: "")).font(Typeface.monoSmall).foregroundStyle(theme.ok)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline.opacity(0.6)).frame(height: 0.5) }
    }

    /// The matching letters, highlighted (spec §4.6).
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        for range in MatchHighlighter.ranges(of: query, in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].backgroundColor = Color.yellow.opacity(theme.isDark ? 0.35 : 0.45)
            attributed[lower..<upper].font = .subheadline.bold()
        }
        return attributed
    }

    private func albumOf(_ track: TrackRow) -> AlbumCard? {
        library.albums.first { $0.title == track.album && library.tracks(of: $0.id).contains { $0.id == track.id } }
    }

    @ViewBuilder
    private func upNextMenu(_ album: AlbumCard, from track: TrackRow.ID? = nil) -> some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            playback.playNext(album, startingAt: track)
        }
        Button("Add to Up Next", systemImage: "text.append") { playback.addToUpNext(album, startingAt: track) }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button("Import from Files", systemImage: "folder") { importing = true }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("shelfImport")
                Button("Get Music", systemImage: "arrow.down.circle") { getMusic() }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("shelfGetMusic")
            }
            if let importNote {
                Text(importNote).font(.footnote).foregroundStyle(theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("importNote")
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
    }
}

/// A sleeve in the crate: the cover, with a thin edge highlight.
struct Sleeve: View {
    let album: AlbumCard

    var body: some View {
        ArtworkView(albumID: album.id, artwork: album.artwork)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 6)
    }
}

extension SearchFilter {
    var label: String {
        switch self {
        case .all: "All"
        case .albums: "Albums"
        case .songs: "Songs"
        case .hiRes24: "24-bit+"
        case .bit32: "32-bit"
        case .rate96: "≥96 kHz"
        }
    }

    /// A stable name for accessibility ids.
    var key: String {
        switch self {
        case .all: "all"
        case .albums: "albums"
        case .songs: "songs"
        case .hiRes24: "24bit"
        case .bit32: "32bit"
        case .rate96: "96k"
        }
    }
}
