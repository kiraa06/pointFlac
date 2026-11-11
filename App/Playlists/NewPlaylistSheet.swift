import PFCore
import PFDesign
import SwiftUI

/// The eight pressing colours (spec §3), in the picker's order, each drawn as a small vinyl disc of its colour; the
/// chosen one ringed. Each announces its colour's name and is selectable (spec §6).
struct PressingSwatches: View {
    @Binding var selection: PressingColour
    let theme: Theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PressingColour.allCases, id: \.self) { colour in
                let chosen = colour == selection
                Button {
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.3)) {
                        selection = colour
                    }
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(theme.ink.opacity(chosen ? 0.92 : 0), lineWidth: 2)
                            .frame(width: 37, height: 37)
                            .scaleEffect(chosen || reduceMotion ? 1 : 0.8)
                        PressingDisc(look: .swatch(colour), size: 26)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(colour.name)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("pressingColour-\(colour.rawValue)")
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// The name field the playlist sheets share: centred, a size up from body, on a soft field with a pencil saying it can
/// be changed. A name is 1 to 60 characters; longer is cut as it is typed.
struct PlaylistNameField: View {
    @Binding var name: String
    let theme: Theme
    var identifier = "playlistName"
    var commit: () -> Void = {}
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        HStack(spacing: 8) {
            TextField("Playlist name", text: $name, selection: $selection)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(commit)
                .accessibilityIdentifier(identifier)
            Image(systemName: "pencil")
                .font(.subheadline)
                .foregroundStyle(theme.inkSecondary.opacity(0.8))
                .accessibilityHidden(true)
        }
        .padding(.leading, 34)
        .padding(.trailing, 12)
        .frame(minHeight: 46)
        // A long name stays readable rather than cut to a few letters at the largest sizes.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.hairline.opacity(0.55)))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { focused = true }
        .onChange(of: name) { _, now in
            if now.count > Playlist.maxNameLength { name = String(now.prefix(Playlist.maxNameLength)) }
        }
        .onChange(of: focused) { _, now in
            if now {
                // Focused, the whole name is selected, so typing replaces the default rather than adding to it.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(30))
                    selection = TextSelection(range: name.startIndex..<name.endIndex)
                }
            } else {
                commit()
            }
        }
    }
}

/// The New Playlist form (spec §4): a live preview of the pressing at 180 pt, the name (default "New Playlist",
/// "New Playlist 2"…), the eight colours and Create. In a sheet of its own from the strip's New, or inside the Add to
/// Playlist sheet, where the playlist is made with the songs being added.
struct NewPlaylistForm: View {
    let desk: PlaylistDesk
    /// The songs the playlist starts with, from the Add to Playlist sheet.
    var request: PlaylistAddRequest?
    let theme: Theme
    let cancel: () -> Void
    let created: (PlaylistCard) -> Void
    @State private var name: String
    @State private var colour: PressingColour
    @State private var creating = false
    @Environment(\.isMonochrome) private var mono

    init(
        desk: PlaylistDesk, request: PlaylistAddRequest? = nil, theme: Theme, cancel: @escaping () -> Void,
        created: @escaping (PlaylistCard) -> Void
    ) {
        self.desk = desk
        self.request = request
        self.theme = theme
        self.cancel = cancel
        self.created = created
        _name = State(initialValue: desk.nextName)
        _colour = State(initialValue: desk.nextColour)
    }

    /// The pressing as it will be made: the name typed (or the default it falls back to), the colour picked, and the
    /// covers of the songs it starts with.
    private var draft: PressingLook {
        .draft(
            name: Playlist.validName(name) ?? desk.nextName, colour: colour, covers: request?.covers ?? [],
            songCount: request?.songs.count ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            RecordView(face: RecordFace(pressing: draft, side: "A", bands: []), diameter: 180)
                .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.2), radius: 14, y: 8)
                .padding(.top, 6)
                .padding(.bottom, 22)
                .animation(.easeInOut(duration: 0.25), value: colour)
            PlaylistNameField(name: $name, theme: theme, identifier: "newPlaylistName")
                .padding(.horizontal, 16)
            PressingSwatches(selection: $colour, theme: theme)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            Button {
                create()
            } label: {
                Text("Create")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .foregroundStyle(colour.wantsDarkInk && !mono ? Color.black.opacity(0.85) : .white)
            }
            .buttonStyle(.glassProminent)
            .tint(colour.ui(monochrome: mono))
            .controlSize(.large)
            .disabled(creating)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .accessibilityIdentifier("createPlaylist")
        }
        .navigationTitle("New Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier("cancelNewPlaylist")
            }
        }
    }

    private func create() {
        guard !creating else { return }
        creating = true
        Task {
            if let made = await desk.create(name: name, colour: colour, adding: request?.songs ?? []) {
                created(made)
            } else {
                creating = false
            }
        }
    }
}

/// New Playlist on its own (from the strip's New disc): the form, in a sheet sized to it.
struct NewPlaylistSheet: View {
    let desk: PlaylistDesk
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isMonochrome) private var mono
    @State private var height: CGFloat = 520

    var body: some View {
        let theme = Theme.look(stage: .deck, dark: scheme == .dark, monochrome: mono)
        NavigationStack {
            NewPlaylistForm(desk: desk, theme: theme, cancel: { dismiss() }, created: { _ in dismiss() })
                .padding(.bottom, 20)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    height = $0
                }
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .presentationDetents([.height(height + 48), .large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("newPlaylistSheet")
    }
}
