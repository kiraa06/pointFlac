import SwiftUI

/// Downloads (spec §4.7): one list for every source, with each transfer's state and progress. A download counts as
/// done only after validation and saving; the states come from the finder as words.
struct DownloadsView: View {
    let finder: any MusicFinding
    @Environment(\.isMonochrome) private var mono

    var body: some View {
        NavigationStack {
            List {
                if finder.downloads.isEmpty {
                    ContentUnavailableView(
                        "No downloads", systemImage: "arrow.down.circle",
                        description: Text("Find FLAC in Get Music and tap Download. Transfers show here."))
                }
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
                    .swipeActions {
                        if row.state.hasPrefix("Failed") || row.state.hasPrefix("Cancelled") {
                            Button("Retry", systemImage: "arrow.clockwise") { finder.retryDownload(row.id) }
                                .tint(mono ? .primary : .blue)
                        } else if !row.state.hasPrefix("Done") {
                            Button("Cancel", systemImage: "xmark", role: .destructive) {
                                finder.cancelDownload(row.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
        }
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
        if mono { return state.hasPrefix("Done") || state.hasPrefix("Failed") ? .primary : .secondary }
        if state.hasPrefix("Done") { return .green }
        if state.hasPrefix("Failed") { return .orange }
        return .secondary
    }
}
