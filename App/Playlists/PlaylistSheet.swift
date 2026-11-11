import PFCore
import PFDesign
import SwiftUI

/// A playlist's own sheet (spec §4): its pressing, large and turning at 33⅓ (still under Reduce Motion); its name,
/// editable except for Favourites; the colours; Play; and its songs, each with its own album's cover, which swipe left
/// to remove and, under Edit, drag to reorder. Delete Playlist… closes the list, except for Favourites.
///
/// Editing the playlist on the deck changes nothing that plays: the songs cued stay until it is put on again.
struct PlaylistSheet: View {
    let desk: PlaylistDesk
    let playlistID: PlaylistCard.ID
    /// Puts the playlist on the deck, from a song or from the top; nil where the sheet can't (no player behind it).
    let play: ((AlbumCard, TrackRow.ID?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isMonochrome) private var mono
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editMode: EditMode = .inactive
    @State private var name = ""
    @State private var askingToDelete = false
    @ScaledMetric(relativeTo: .body) private var scaledCover: CGFloat = 40
    /// The floating Edit and Done buttons' height, so at the largest text sizes the pressing clears them.
    @State private var barHeight: CGFloat = 64

    /// The songs' covers grow with the type, up to a point.
    private var coverSide: CGFloat { min(scaledCover, 64) }

    private var theme: Theme { .look(stage: .deck, dark: scheme == .dark, monochrome: mono) }

    var body: some View {
        Group {
            if let card = desk.playlist(playlistID) {
                content(card)
            } else {
                // Deleted (here or elsewhere): nothing left to show.
                Color.clear.onAppear { dismiss() }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playlistSheet")
    }

    private func content(_ card: PlaylistCard) -> some View {
        let songs = desk.songs(of: card.id)
        return ZStack(alignment: .top) {
            List {
                top(card, songs: songs)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .moveDisabled(true)
                Section {
                    if songs.isEmpty {
                        Text("No songs yet. Tap ♥ on the player, or long-press any album or song to add it.")
                            .font(.subheadline)
                            .foregroundStyle(theme.inkSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("playlistEmpty")
                    }
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        row(song, index: index, card: card)
                    }
                    .onMove { from, to in
                        var ids = songs.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        desk.reorder(card.id, songs: ids)
                    }
                } header: {
                    if !songs.isEmpty { songHead(card, songs: songs) }
                }
                if !card.isFavourites {
                    Button(role: .destructive) {
                        askingToDelete = true
                    } label: {
                        Text("Delete Playlist…")
                            .font(.body)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.hairline.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .monoForeground(.red)
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 30, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .moveDisabled(true)
                    .accessibilityIdentifier("deletePlaylist")
                    .confirmationDialog(card.name, isPresented: $askingToDelete, titleVisibility: .visible) {
                        Button("Delete Playlist", role: .destructive) {
                            desk.delete(card.id)
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deletes this playlist. The songs stay in your library.")
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
            .contentMargins(.top, 8, for: .scrollContent)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListHeaderHeight, 1)
            bar(songs: songs)
        }
        .onAppear { name = card.name }
        .onChange(of: card.name) { _, now in name = now }
    }

    /// Edit at the top left (it turns on drag-to-reorder), Done at the top right, floating over the pressing.
    private func bar(songs: [TrackRow]) -> some View {
        HStack {
            Button(editMode.isEditing ? "Done" : "Edit") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(songs.count < 2 && !editMode.isEditing)
            .accessibilityIdentifier("editPlaylist")
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("closePlaylist")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            barHeight = $0
        }
    }

    /// The pressing, the name, the colours and Play.
    private func top(_ card: PlaylistCard, songs: [TrackRow]) -> some View {
        VStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
                // A true 33⅓, clockwise: 200° a second. Only the print turns; the light stays put.
                let angle =
                    reduceMotion
                    ? 0 : (context.date.timeIntervalSinceReferenceDate * 200).truncatingRemainder(dividingBy: 360)
                RecordView(
                    face: RecordFace(pressing: card.look, side: "A", bands: bands(songs)), diameter: 176, angle: angle)
            }
            .frame(width: 176, height: 176)
            .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.22), radius: 16, y: 10)
            // Between Edit and Done; under them once large type has widened them.
            .padding(.top, typeSize.isAccessibilitySize ? barHeight + 4 : 40)
            .padding(.bottom, 22)
            .accessibilityHidden(true)
            if card.isFavourites {
                Text(card.name)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("playlistName")
            } else {
                PlaylistNameField(name: $name, theme: theme) {
                    if Playlist.validName(name) == nil {
                        name = card.name
                    } else if name != card.name {
                        desk.rename(card.id, to: name)
                    }
                }
                .padding(.horizontal, 16)
            }
            PressingSwatches(
                selection: Binding(get: { card.colour }, set: { desk.recolour(card.id, to: $0) }), theme: theme
            )
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if let play {
                Button {
                    play(card.albumCard, nil)
                    dismiss()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(card.colour.wantsDarkInk && !mono ? Color.black.opacity(0.85) : .white)
                }
                .buttonStyle(.glassProminent)
                .tint(card.colour.ui(monochrome: mono))
                .controlSize(.large)
                .disabled(songs.isEmpty)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .accessibilityIdentifier("playPlaylist")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
    }

    /// "6 songs · 28 min", and how to remove one.
    private func songHead(_ card: PlaylistCard, songs: [TrackRow]) -> some View {
        let total = songs.reduce(0) { $0 + $1.durationSeconds }
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Text("\(card.countText) · \(card.durationText(total))")
                .foregroundStyle(theme.inkSecondary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Text(editMode.isEditing ? "Drag to reorder" : "Swipe left to remove")
                .foregroundStyle(theme.inkSecondary.opacity(0.65))
        }
        .font(.footnote)
        .textCase(nil)
        .padding(.top, 6)
    }

    private func row(_ song: TrackRow, index: Int, card: PlaylistCard) -> some View {
        Button {
            guard !editMode.isEditing, let play else { return }
            play(card.albumCard, song.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ArtworkView(albumID: song.albumID ?? song.album, artwork: nil, pixels: 120)
                    .frame(width: coverSide, height: coverSide)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
                            theme.hairline, lineWidth: 0.5)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    Text("\(song.artist) · \(song.album)")
                        .font(.footnote)
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                Spacer(minLength: 8)
                Text(Tracklist.clock(song.durationSeconds))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 20))
        .alignmentGuide(.listRowSeparatorLeading) { [indent = coverSide + 12] _ in indent }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                desk.remove([song.id], from: card.id)
            }
            .monoDestructive()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(song.title), \(song.artist), \(song.album), \(Tracklist.spoken(song.durationSeconds))")
        .accessibilityHint(play == nil ? "" : "Plays the playlist from this song")
        .accessibilityAction(named: "Remove from Playlist") { desk.remove([song.id], from: card.id) }
        .accessibilityIdentifier("playlistSong-\(index)")
    }

    /// Side A's track gaps, for the turning pressing.
    private func bands(_ songs: [TrackRow]) -> [CGFloat] {
        let layout = SideLayout(durations: songs.map(\.durationSeconds))
        guard !layout.sides.isEmpty else { return [] }
        return RecordFace.bands(for: SideTimeline(durations: layout.durations(onSide: 0)))
    }
}
