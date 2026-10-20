import PFCore
import PFLibrary
import SwiftUI
import UniformTypeIdentifiers

/// Plan 1's stand-in for the library: the imported tracks, what the latest import refused, and an Add button that
/// opens the Files picker. Tapping a track plays it alone; Play All queues the library, for next, previous and gapless
/// joins. A track v1 cannot play (multichannel, spec §5.3) is listed as "Not supported in v1" and cannot be tapped.
/// Now Playing sits at the bottom.
struct DebugLibraryView: View {
    /// The SDK has no `UTType.flac`; the extension resolves to the system's `org.xiph.flac`. Should it ever not
    /// resolve, the picker offers all audio, and the inbox still refuses anything that is not FLAC.
    private static let flac = UTType(filenameExtension: "flac") ?? .audio

    let model: AppModel
    @State private var picking = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.outputError {
                    Section {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("outputError")
                    }
                }
                Section("Tracks") {
                    if model.files.isEmpty {
                        Text("No tracks yet. Tap Add to bring in FLAC files from Files.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Play All", systemImage: "play.square.stack") {
                            Task { await model.playAll() }
                        }
                        .disabled(model.player == nil || !model.files.contains(where: \.isSupported))
                        .accessibilityIdentifier("playAllButton")
                    }
                    ForEach(model.files) { file in
                        Button {
                            Task { await model.play(file) }
                        } label: {
                            TrackRow(file: file)
                        }
                        .disabled(model.player == nil || !file.isSupported)
                        .accessibilityIdentifier("trackRow-\(file.stem)")
                    }
                }
                if !model.rejections.isEmpty {
                    Section("Not added") {
                        ForEach(Array(model.rejections.enumerated()), id: \.offset) { _, rejection in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rejection.fileName)
                                Text(rejection.message).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let summary = model.importSummary {
                    Section {
                        Text(summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("pointFlac")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { picking = true }
                        .accessibilityIdentifier("importButton")
                }
            }
            .fileImporter(
                isPresented: $picking, allowedContentTypes: [Self.flac],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls): Task { await model.importFiles(urls) }
                case .failure(let error): model.importFailed(error)
                }
            }
            .refreshable { await model.reload() }
            .safeAreaInset(edge: .bottom) {
                if let player = model.player {
                    DebugNowPlayingView(player: player)
                }
            }
        }
        .task { await model.load() }
    }
}

/// A track's title, with its artist and format under it, and a note when v1 cannot play it.
private struct TrackRow: View {
    let file: ImportedFile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.title)
            Text(details).font(.footnote).foregroundStyle(.secondary)
            if !file.isSupported {
                Text("Not supported in v1").font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    private var details: String {
        let format = "\(file.format.formattedDepth) · \(file.format.formattedRate)"
        return file.artist.isEmpty ? "\(file.id) · \(format)" : "\(file.artist) · \(file.id) · \(format)"
    }
}
