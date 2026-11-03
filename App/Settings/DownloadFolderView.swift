import SwiftUI
import UniformTypeIdentifiers

/// Settings → Downloads → Save downloads to: in the app (the default), or in a folder picked in Files, where songs
/// survive pointFlac being deleted. Kiran lost every download when his free-provisioning install expired and the app
/// was deleted with its container; a folder in iCloud Drive keeps them, and on his other devices too.
///
/// Picking a folder adds it to the library (`DownloadFolder.choose`), so songs already in it appear on the shelf.
/// Going back to "In pointFlac" only stops new downloads going to the folder. When the folder can't be reached,
/// downloads are saved in the app instead and this screen says so, until the folder is chosen again.
struct DownloadFolderView: View {
    let folder: DownloadFolder
    @State private var picking = false
    @Environment(\.isMonochrome) private var mono
    @Environment(\.colorScheme) private var scheme

    private var theme: Theme { .look(stage: .deck, dark: scheme == .dark, monochrome: mono) }

    var body: some View {
        Form {
            Section {
                appOption
                folderOption
                if case .unavailable = folder.status { unavailableWarning }
                if folder.isAdding {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Adding the folder's songs to your library…").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("downloadFolderAdding")
                }
                if let error = folder.pickError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(theme.warn)
                        .accessibilityIdentifier("downloadFolderError")
                }
            } footer: {
                Text(
                    "Songs saved to a folder you choose stay there even if pointFlac is deleted. "
                        + "A folder in iCloud Drive also keeps them on your other devices.")
            }
        }
        .navigationTitle("Save downloads to")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): Task { await folder.choose(url) }
            case .failure(let error): folder.pickerFailed(error)
            }
        }
    }

    /// Where downloads actually go: the app by default, and while the picked folder can't be reached.
    private var appSelected: Bool {
        switch folder.status {
        case .app, .unavailable: true
        case .folder: false
        }
    }

    private var appOption: some View {
        Button {
            folder.useApp()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("In pointFlac").foregroundStyle(.primary)
                    Text(
                        "Kept inside the app: deleting pointFlac deletes these songs. "
                            + "You can still see them in Files → On My iPhone → pointFlac."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                checkmark(appSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In pointFlac")
        .accessibilityHint("Kept inside the app: deleting pointFlac deletes these songs.")
        .accessibilityAddTraits(appSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("downloadDestinationApp")
    }

    /// "A folder in Files…" until one is picked; then the folder with "Change…", ticked while downloads go there.
    /// While it can't be reached it is not ticked ("In pointFlac" is, since downloads go there), and the warning below
    /// offers "Choose again…".
    @ViewBuilder
    private var folderOption: some View {
        switch folder.status {
        case .app:
            Button("A folder in Files…") { picking = true }
                .accessibilityLabel("A folder in Files")
                .accessibilityHint("Opens Files to pick the folder downloads are saved to.")
                .accessibilityIdentifier("downloadDestinationFolder")
        case .folder(let name), .unavailable(let name):
            let selected = !appSelected
            HStack {
                Label(name, systemImage: "folder")
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 8)
                checkmark(selected)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(selected ? "Folder \(name)" : "Folder \(name), unavailable")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("downloadDestinationFolder")
            if case .folder = folder.status {
                Button("Change…") { picking = true }
                    .accessibilityLabel("Change folder")
                    .accessibilityIdentifier("downloadDestinationChange")
            }
        }
    }

    private var unavailableWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Can't reach this folder. New downloads are saved in pointFlac until you choose it again.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(theme.warn)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("downloadFolderUnavailable")
            Button("Choose again…") { picking = true }
                .accessibilityLabel("Choose the folder again")
                .accessibilityIdentifier("downloadDestinationChooseAgain")
        }
    }

    private func checkmark(_ selected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
            .opacity(selected ? 1 : 0)
            .accessibilityHidden(true)
    }
}
