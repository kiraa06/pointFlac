import SwiftUI
import UniformTypeIdentifiers

/// Get Music (spec §4.7): import from Files, and search the online providers. As you type, the field offers
/// suggestions (contract 3: library hits at once, registry hits after); picking one searches with that entity, and
/// Search searches the words. Results stream in by provider with their format and size; Internet Archive rows carry
/// their licence. Tap Download to queue a transfer, which shows in Downloads.
struct GetMusicView: View {
    let finder: any MusicFinding
    let library: any LibraryBrowsing

    @State private var query = ""
    @State private var provider = ""
    @State private var suggestions: [Suggestion] = []
    @State private var results: [RemoteResultRow] = []
    @State private var searching = false
    /// What the results are for: the typed words, or a picked suggestion.
    @State private var request: Request?
    @State private var importing = false
    @State private var importNote: String?
    @AppStorage(AppModel.lookupNamesKey) private var lookupNames = true
    /// Ruling R26: the MusicBrainz note shows under the field until the person has seen it once, then lives behind
    /// an info button.
    @AppStorage("musicBrainzNoteSeen") private var noteSeen = false
    @State private var showingNote = false

    static let musicBrainzNote =
        "Suggestions use MusicBrainz: what you type is sent to musicbrainz.org. Change in Settings."

    private static let flac = UTType(filenameExtension: "flac") ?? .audio

    enum Request: Equatable {
        case words(String, provider: String)
        case entity(Suggestion, provider: String)
    }

    var body: some View {
        NavigationStack {
            List {
                if lookupNames, !noteSeen {
                    Text(Self.musicBrainzNote)
                        .font(.caption).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("musicBrainzNote")
                        .onDisappear { noteSeen = true }
                }
                Section {
                    Picker("Source", selection: $provider) {
                        ForEach(finder.providers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("providerPicker")
                }
                if request == nil, !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                request = .entity(suggestion, provider: provider)
                            } label: {
                                SuggestionLine(suggestion: suggestion)
                            }
                            .accessibilityIdentifier("suggestion-\(index)")
                        }
                    }
                }
                if request != nil {
                    Section {
                        if results.isEmpty {
                            HStack {
                                ProgressView()
                                Text(searching ? "Searching…" : "No FLAC results").foregroundStyle(.secondary)
                            }
                        }
                        let queued = Set(finder.downloads.map(\.id))
                        ForEach(results) { row in
                            if row.children.isEmpty {
                                RemoteRowView(row: row, downloaded: queued.contains(row.id)) { finder.download(row) }
                            } else {
                                // A folder or album: its own button takes every song; open it to take one song.
                                DisclosureGroup {
                                    ForEach(row.children) { song in
                                        RemoteRowView(row: song, downloaded: queued.contains(song.id), isSong: true) {
                                            finder.download(song)
                                        }
                                    }
                                } label: {
                                    RemoteRowView(
                                        row: row, downloaded: row.children.allSatisfy { queued.contains($0.id) }
                                    ) {
                                        finder.download(row)
                                    }
                                }
                                .accessibilityIdentifier("folder-\(row.id)")
                            }
                        }
                    } header: {
                        Text(resultsHeader)
                    }
                }
                Section {
                    Button("Import from Files", systemImage: "folder") { importing = true }
                        .accessibilityIdentifier("getMusicImport")
                    if let importNote {
                        Text(importNote).font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Files are checked against their actual bytes: only real FLAC gets in.")
                }
            }
            .navigationTitle("Get Music")
            .toolbar {
                if lookupNames, noteSeen {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("About suggestions", systemImage: "info.circle") { showingNote = true }
                            .accessibilityIdentifier("musicBrainzInfo")
                    }
                }
            }
            .alert("Suggestions", isPresented: $showingNote) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(Self.musicBrainzNote)
            }
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artist, album or song"
            )
            .onSubmit(of: .search) {
                guard !query.isEmpty else { return }
                request = .words(query, provider: provider)
            }
            .onChange(of: query) { request = nil }
            .onChange(of: provider) {
                switch request {
                case .words(let words, _): request = .words(words, provider: provider)
                case .entity(let s, _): request = .entity(s, provider: provider)
                case nil: break
                }
            }
            .task(id: query) {
                // A new phrase cancels the old consumer: this task restarts on every keystroke. The previous rows stay
                // until new ones arrive (no flicker), and a short pause lets fast typing skip phrases nobody reads.
                guard !query.isEmpty else {
                    suggestions = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                for await batch in finder.suggestions(query) {
                    guard !Task.isCancelled else { return }
                    suggestions = batch
                }
            }
            .task(id: request) {
                results = []
                guard let request else { return }
                searching = true
                let stream: AsyncStream<[RemoteResultRow]> =
                    switch request {
                    case .words(let words, let p): finder.search(words, provider: p)
                    case .entity(let s, let p): finder.search(s, provider: p)
                    }
                for await batch in stream {
                    results = batch
                }
                searching = false
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [Self.flac], allowsMultipleSelection: true) {
                result in
                switch result {
                case .success(let urls):
                    Task {
                        let outcome = await library.importFiles(urls)
                        importNote =
                            "\(outcome.added) added" + (outcome.rejected.isEmpty ? "" : ", not added: ")
                            + outcome.rejected.joined(separator: "; ")
                    }
                case .failure(let error):
                    importNote = "The picker failed: \(error.localizedDescription)"
                }
            }
            .onAppear {
                if provider.isEmpty { provider = finder.providers.first?.id ?? "" }
            }
        }
    }

    private var resultsHeader: String {
        let name = finder.providers.first { $0.id == provider }?.name ?? provider
        switch request {
        case .words(let words, _): return "\(name) · “\(words)”"
        case .entity(let s, _): return "\(name) · \(s.title)"
        case nil: return name
        }
    }
}

private struct SuggestionLine: View {
    let suggestion: Suggestion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title).foregroundStyle(.primary)
                Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(suggestion.source == "library" ? "Library" : "MusicBrainz")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch suggestion.kind {
        case .artist: "person"
        case .album: "square.stack"
        case .track: "music.note"
        }
    }
}

private struct RemoteRowView: View {
    let row: RemoteResultRow
    let downloaded: Bool
    /// A song inside an open folder: lighter type, no subtitle.
    var isSong = false
    let download: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(isSong ? .subheadline : .body.weight(.semibold)).lineLimit(2)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(row.format).font(.caption.monospaced()).foregroundStyle(.tint)
                    Text(row.sizeText).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let licence = row.licence {
                    Label(licence, systemImage: "checkmark.seal")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("licence-\(row.id)")
                }
            }
            Spacer(minLength: 4)
            Button(action: download) {
                Image(systemName: downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(downloaded)
            .accessibilityLabel(
                downloaded ? "Queued" : row.children.isEmpty ? "Download \(row.title)" : "Download all of \(row.title)"
            )
            .accessibilityIdentifier("download-\(row.id)")
        }
        .padding(.vertical, 2)
    }
}
