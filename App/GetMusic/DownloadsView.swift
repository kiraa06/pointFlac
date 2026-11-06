import SwiftUI

/// Downloads (spec §4.7): one list for every source, with each transfer's state and progress. A download counts as
/// done only after validation and saving; the states come from the finder as words.
///
/// Every row shows the controls that apply to it as icon buttons at its trailing edge: Pause and Cancel while it
/// transfers, Resume and Cancel once paused, Retry and Remove once it failed or was cancelled. A finished row shows only
/// its tick. Holding a row offers the same actions; a finished one also offers Remove from List, which only tidies the
/// list (the song stays in the library), and Delete Song…, which deletes the song itself after saying exactly what will
/// happen to its file. Swiping a row offers them too. The toolbar's menu pauses, resumes or cancels every download at
/// once, and clears finished or failed rows.
struct DownloadsView: View {
    let finder: any MusicFinding
    /// For deleting a finished download's song: what that would do, and the deletion itself.
    let library: any LibraryBrowsing
    /// The deck lets go of a song before it is deleted, so nothing plays a file as it goes.
    let playback: PlaybackController
    @Environment(\.isMonochrome) private var mono
    @Environment(\.colorScheme) private var scheme
    /// The finished download whose song waits for the user to confirm its deletion.
    @State private var pendingDelete: PendingSongDelete?
    @State private var cancelAllAsked = false
    /// One line about the latest song deletion, when it did not go as planned.
    @State private var deleteNote: String?

    private var theme: Theme { .look(stage: .deck, dark: scheme == .dark, monochrome: mono) }

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
                        rowView(row)
                    }
                } footer: {
                    if !finder.downloads.isEmpty || deleteNote != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if let deleteNote {
                                Text(deleteNote).foregroundStyle(theme.warn)
                                    .accessibilityIdentifier("downloadsNote")
                            }
                            if !finder.downloads.isEmpty {
                                Text("Removing a finished download keeps the song in your library.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar { toolbarMenu }
        }
    }

    // MARK: Rows

    private func rowView(_ row: DownloadRow) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.title).font(.body.weight(.semibold)).lineLimit(1)
                if let progress = row.progress {
                    ProgressView(value: progress)
                        .accessibilityIdentifier("downloadProgress-\(row.id)")
                }
                Text(stateLine(row))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(row.phase == .stopped && row.state.hasPrefix("Failed") ? theme.warn : .secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("downloadState-\(row.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("downloadRow-\(row.id)")
            trailing(row)
        }
        .padding(.vertical, 4)
        .contextMenu { menu(row) }
        .swipeActions { swipeActions(row) }
        // On the row, so the dialog points at the song it deletes.
        .confirmationDialog(
            row.title, isPresented: deleteAsked(row), titleVisibility: .visible, presenting: pendingDelete
        ) { pending in
            Button(pending.action, role: .destructive) { delete(pending) }
                .accessibilityIdentifier("deleteDownloadedSong")
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    /// The row's own controls, or its status when it has none: the tick once done, a quiet arrow while it is being
    /// checked and saved.
    @ViewBuilder
    private func trailing(_ row: DownloadRow) -> some View {
        switch row.phase {
        case .transferring:
            HStack(spacing: 0) {
                control("Pause", "pause.fill", id: "downloadPause-\(row.id)") { finder.pauseDownload(row.id) }
                control("Cancel", "xmark", id: "downloadCancel-\(row.id)", secondary: true) {
                    finder.cancelDownload(row.id)
                }
            }
        case .paused:
            HStack(spacing: 0) {
                control("Resume", "play.fill", id: "downloadResume-\(row.id)") { finder.resumeDownload(row.id) }
                control("Cancel", "xmark", id: "downloadCancel-\(row.id)", secondary: true) {
                    finder.cancelDownload(row.id)
                }
            }
        case .stopped:
            HStack(spacing: 0) {
                control("Retry", "arrow.clockwise", id: "downloadRetry-\(row.id)") { finder.retryDownload(row.id) }
                control("Remove", "trash", id: "downloadRemove-\(row.id)", secondary: true) {
                    finder.removeDownload(row.id)
                }
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.ok)
                .accessibilityHidden(true)
        case .finishing:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// An icon button with a 44 pt square to tap, in the tint (Monochrome's grey under Monochrome); a secondary one,
    /// Cancel or Remove, in the theme's secondary ink so the row's main action leads.
    private func control(
        _ title: String, _ symbol: String, id: String, secondary: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(secondary ? AnyShapeStyle(theme.inkSecondary) : AnyShapeStyle(.tint))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    /// Holding a row: the actions that apply to it.
    @ViewBuilder
    private func menu(_ row: DownloadRow) -> some View {
        switch row.phase {
        case .transferring:
            Button("Pause", systemImage: "pause.fill") { finder.pauseDownload(row.id) }
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { finder.cancelDownload(row.id) }
        case .paused:
            Button("Resume", systemImage: "play.fill") { finder.resumeDownload(row.id) }
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { finder.cancelDownload(row.id) }
        case .stopped:
            Button("Retry", systemImage: "arrow.clockwise") { finder.retryDownload(row.id) }
            Button("Remove from List", systemImage: "minus.circle") { finder.removeDownload(row.id) }
        case .done:
            Button("Remove from List", systemImage: "minus.circle") { finder.removeDownload(row.id) }
            // A lookup only: the plan, which reads the file's folder, is worked out once the user asks.
            if let track = row.trackID, library.hasTrack(track) {
                Button("Delete Song…", systemImage: "trash", role: .destructive) { askToDelete(row) }
            }
        case .finishing:
            EmptyView()
        }
    }

    /// Done rows can be removed; failed and cancelled ones retried or removed; paused ones resumed; the rest, still
    /// under way, paused or cancelled.
    @ViewBuilder
    private func swipeActions(_ row: DownloadRow) -> some View {
        switch row.phase {
        case .stopped:
            Button("Retry", systemImage: "arrow.clockwise") { finder.retryDownload(row.id) }
                .tint(mono ? .primary : .blue)
            Button("Remove", systemImage: "trash", role: .destructive) { finder.removeDownload(row.id) }
                .monoDestructive()
        case .done:
            Button("Remove", systemImage: "trash", role: .destructive) { finder.removeDownload(row.id) }
                .monoDestructive()
        case .paused:
            Button("Cancel", systemImage: "xmark", role: .destructive) { finder.cancelDownload(row.id) }
                .monoDestructive()
            Button("Resume", systemImage: "play.fill") { finder.resumeDownload(row.id) }
                .tint(mono ? .primary : .blue)
        case .transferring:
            Button("Cancel", systemImage: "xmark", role: .destructive) { finder.cancelDownload(row.id) }
                .monoDestructive()
            Button("Pause", systemImage: "pause.fill") { finder.pauseDownload(row.id) }
                .tint(mono ? Color(white: 0.5) : .indigo)
        case .finishing:
            Button("Cancel", systemImage: "xmark", role: .destructive) { finder.cancelDownload(row.id) }
                .monoDestructive()
        }
    }

    /// The state, with progress while transferring; a finished row's note, when it has one, replaces its "Done".
    private func stateLine(_ row: DownloadRow) -> String {
        guard let progress = row.progress else { return row.note ?? row.state }
        return "\(row.state) · \(Int((progress * 100).rounded()))%"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        let rows = finder.downloads
        let pausable = rows.contains { $0.phase == .transferring }
        let paused = rows.contains { $0.phase == .paused }
        let finished = rows.contains { $0.phase == .done }
        let failed = rows.contains { $0.phase == .stopped }
        if pausable || paused || finished || failed {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if pausable {
                        Button("Pause All", systemImage: "pause.fill") { finder.pauseAllDownloads() }
                            .accessibilityIdentifier("pauseAll")
                    }
                    if paused {
                        Button("Resume All", systemImage: "play.fill") { finder.resumeAllDownloads() }
                            .accessibilityIdentifier("resumeAll")
                    }
                    if pausable || paused {
                        Button("Cancel All…", systemImage: "xmark", role: .destructive) { cancelAllAsked = true }
                            .accessibilityIdentifier("cancelAll")
                    }
                    if finished || failed {
                        Divider()
                    }
                    if finished {
                        Button("Clear Finished", systemImage: "checkmark.circle") {
                            finder.clearDownloads(finished: true, failed: false)
                        }
                        .accessibilityIdentifier("clearFinished")
                    }
                    if failed {
                        Button("Clear Failed", systemImage: "exclamationmark.circle") {
                            finder.clearDownloads(finished: false, failed: true)
                        }
                        .accessibilityIdentifier("clearFailed")
                    }
                } label: {
                    Label("Download Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("downloadsMenu")
                .confirmationDialog(
                    "Cancel all downloads?", isPresented: $cancelAllAsked, titleVisibility: .visible
                ) {
                    Button("Cancel All Downloads", role: .destructive) { finder.cancelAllDownloads() }
                        .accessibilityIdentifier("confirmCancelAll")
                    Button("Keep Downloading", role: .cancel) {}
                } message: {
                    Text("Their partial files are deleted. Songs already downloaded stay in your library.")
                }
            }
        }
    }

    // MARK: Deleting the song

    /// Whether `row`'s song waits for the user to confirm its deletion.
    private func deleteAsked(_ row: DownloadRow) -> Binding<Bool> {
        Binding(
            get: { pendingDelete?.rowID == row.id },
            set: { if !$0, pendingDelete?.rowID == row.id { pendingDelete = nil } })
    }

    /// What deleting a finished download's song would do, or nil when there is no song to delete: the library could
    /// not name its track, or the song has gone from the library since (deleted on the shelf, say).
    private func songPlan(_ row: DownloadRow) -> RemovalPlan? {
        guard row.phase == .done, let track = row.trackID else { return nil }
        let plan = library.removalPlan(album: nil, tracks: [track])
        return plan.tracks.isEmpty ? nil : plan
    }

    private func askToDelete(_ row: DownloadRow) {
        guard let plan = songPlan(row) else { return }
        deleteNote = nil
        pendingDelete = PendingSongDelete(rowID: row.id, plan: plan)
    }

    /// As the shelf deletes: the deck lets go of the song first, so nothing plays a file as it goes, and again
    /// afterwards, in case it was put back on meanwhile. Then the row goes too. A song still in the library afterwards
    /// could not be deleted, and keeps its row; a file that would not move to Recently Deleted is said so.
    private func delete(_ pending: PendingSongDelete) {
        let tracks = pending.plan.tracks
        Task {
            await playback.willRemove(tracks: Set(tracks))
            let outcome = await library.remove(tracks: tracks)
            await playback.willRemove(tracks: Set(tracks))
            if library.removalPlan(album: nil, tracks: tracks).tracks.isEmpty {
                finder.removeDownload(pending.rowID)
                deleteNote = outcome.note
            } else {
                deleteNote = "The song could not be deleted."
            }
        }
    }
}

/// A finished download's song the user asked to delete, and what that would do (`LibraryBrowsing.removalPlan`).
private struct PendingSongDelete {
    let rowID: DownloadRow.ID
    let plan: RemovalPlan

    /// Exactly what happens to the file: deleted from the iPhone (the app's own copy), moved to Recently Deleted (the
    /// download folder), or left in its folder (any other folder pointFlac reads in place).
    var message: String {
        if plan.trashes > 0 {
            "Moves this song to Recently Deleted in Files. You can restore it there for 30 days."
        } else if plan.deletes > 0 {
            "Deletes this song from this iPhone."
        } else {
            "Removes this song from pointFlac. The file stays in its folder."
        }
    }

    /// "Delete Song" when the file leaves its place; "Remove Song" when it stays and only pointFlac forgets it.
    var action: String { plan.trashes + plan.deletes > 0 ? "Delete Song" : "Remove Song" }
}
