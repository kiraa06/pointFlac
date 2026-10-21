import SwiftUI

/// Downloads (spec §4.7): one list for every source, with each transfer's state and progress. A download counts as
/// done only after validation and saving; the states come from the finder as words.
///
/// Finished, failed and cancelled rows can be swiped away, or cleared together from the toolbar. That only tidies the
/// list: a finished download's song is in the library by then, and stays there (the shelf is where songs are deleted).
struct DownloadsView: View {
    let finder: any MusicFinding

    var body: some View {
        NavigationStack {
            List {
                if finder.downloads.isEmpty {
                    ContentUnavailableView(
                        "No downloads", systemImage: "arrow.down.circle",
                        description: Text("Find FLAC in Get Music and tap Download. Transfers show here."))
                }
                Section {
                    ForEach(finder.downloads) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(row.title).font(.body.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Image(systemName: icon(row.state)).foregroundStyle(color(row.state))
                            }
                            if let progress = row.progress {
                                ProgressView(value: progress)
                                    .accessibilityIdentifier("downloadProgress-\(row.id)")
                            }
                            Text(stateLine(row))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("downloadState-\(row.id)")
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("downloadRow-\(row.id)")
                        .swipeActions { swipeActions(row) }
                    }
                } footer: {
                    if !finder.downloads.isEmpty {
                        Text("Removing a finished download keeps the song in your library.")
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                let finished = finder.downloads.contains { Self.isFinished($0.state) }
                let failed = finder.downloads.contains { Self.isFailed($0.state) }
                if finished || failed {
                    Menu("Clear", systemImage: "trash") {
                        if finished {
                            Button("Clear Finished") { finder.clearDownloads(finished: true, failed: false) }
                        }
                        if failed {
                            Button("Clear Failed") { finder.clearDownloads(finished: false, failed: true) }
                        }
                    }
                    .accessibilityIdentifier("clearDownloads")
                }
            }
        }
    }

    /// Done rows can be removed; failed and cancelled ones retried or removed; the rest, still under way, cancelled.
    @ViewBuilder
    private func swipeActions(_ row: DownloadRow) -> some View {
        if Self.isFailed(row.state) {
            Button("Retry", systemImage: "arrow.clockwise") { finder.retryDownload(row.id) }
                .tint(.blue)
            Button("Remove", systemImage: "trash", role: .destructive) { finder.removeDownload(row.id) }
        } else if Self.isFinished(row.state) {
            Button("Remove", systemImage: "trash", role: .destructive) { finder.removeDownload(row.id) }
        } else {
            Button("Cancel", systemImage: "xmark", role: .destructive) { finder.cancelDownload(row.id) }
        }
    }

    /// The finder's words for a published download: "Done", or the demo's "Done (…)".
    private static func isFinished(_ state: String) -> Bool { state.hasPrefix("Done") }

    /// Failed and cancelled downloads: both final, and both can be retried.
    private static func isFailed(_ state: String) -> Bool {
        state.hasPrefix("Failed") || state.hasPrefix("Cancelled")
    }

    private func stateLine(_ row: DownloadRow) -> String {
        guard let progress = row.progress else { return row.state }
        return "\(row.state) · \(Int((progress * 100).rounded()))%"
    }

    private func icon(_ state: String) -> String {
        if state.hasPrefix("Done") { return "checkmark.circle.fill" }
        if state.hasPrefix("Failed") { return "exclamationmark.triangle.fill" }
        if state.hasPrefix("Queued") || state.hasPrefix("Waiting") { return "clock" }
        return "arrow.down.circle"
    }

    private func color(_ state: String) -> Color {
        if state.hasPrefix("Done") { return .green }
        if state.hasPrefix("Failed") { return .orange }
        return .secondary
    }
}
