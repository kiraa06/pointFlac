import PFCore
import PFDesign
import SwiftUI

/// Add to Playlist (spec §4): a medium-detent sheet listing New Playlist… and then every playlist, each with its disc,
/// its name, its song count and a checkmark when every song being added is in it already. Tapping a playlist adds the
/// songs (or, for one song it holds, takes it out); its disc turns a quarter turn, and the sheet closes 350 ms later.
/// New Playlist… opens the New Playlist form in the same sheet, grown to full height, which makes the playlist with the
/// songs in it.
struct AddToPlaylistSheet: View {
    let desk: PlaylistDesk
    let request: PlaylistAddRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isMonochrome) private var mono
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var creating = false
    @State private var detent: PresentationDetent = .medium
    /// Each disc's turn, in degrees: a quarter more for each add, a quarter back for each removal.
    @State private var turns: [PlaylistCard.ID: Double] = [:]
    @State private var picks = 0
    @State private var closing = false

    private var theme: Theme { .look(stage: .deck, dark: scheme == .dark, monochrome: mono) }

    /// A 44 pt disc in a 58 pt row, as the mockup draws them.
    private static let rowInsets = EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 20)

    var body: some View {
        NavigationStack {
            ZStack {
                if creating {
                    ScrollView {
                        NewPlaylistForm(
                            desk: desk, request: request, theme: theme,
                            cancel: {
                                withAnimation(.smooth(duration: 0.3)) {
                                    creating = false
                                    detent = .medium
                                }
                            },
                            created: { _ in dismiss() }
                        )
                        .padding(.bottom, 24)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .transition(.opacity)
                } else {
                    list
                        .transition(.opacity)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: picks)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("addToPlaylistSheet")
    }

    private var list: some View {
        List {
            Button {
                withAnimation(.smooth(duration: 0.35)) {
                    creating = true
                    detent = .large
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .strokeBorder(
                                theme.ink.opacity(0.45), style: StrokeStyle(lineWidth: 1.3, dash: [3.5, 3.5]))
                        Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                    }
                    .frame(width: 44, height: 44)
                    Text("New Playlist…").font(.body.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(Self.rowInsets)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("addToPlaylistNew")
            ForEach(desk.playlists) { card in
                row(card)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // A playlist's name never breaks mid-word: the rows stop growing at the third accessibility size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("Add to Playlist").font(.headline)
                    Text(request.subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
                    .accessibilityIdentifier("closeAddToPlaylist")
            }
        }
    }

    private func row(_ card: PlaylistCard) -> some View {
        let holds = !request.songs.isEmpty && request.songs.allSatisfy(card.songIDs.contains)
        return Button {
            pick(card, holds: holds)
        } label: {
            HStack(spacing: 12) {
                PressingDisc(look: card.look, size: 44)
                    .rotationEffect(.degrees(turns[card.id] ?? 0))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name)
                        .font(.body)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    Text(card.countText)
                        .font(.footnote)
                        .foregroundStyle(theme.inkSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(holds ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(Self.rowInsets)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(card.name), \(card.countText)")
        .accessibilityAddTraits(holds ? .isSelected : [])
        .accessibilityHint(
            holds && request.songs.count == 1
                ? "Takes the song out" : "Adds \(request.songs.count == 1 ? "the song" : "the songs")"
        )
        .accessibilityIdentifier("addToPlaylist-\(card.id)")
    }

    /// The songs go in (or the one song comes out), the disc turns a quarter, and the sheet closes a beat later.
    private func pick(_ card: PlaylistCard, holds: Bool) {
        guard !closing else { return }
        closing = true
        let adding = !(holds && request.songs.count == 1)
        picks += 1
        if !reduceMotion {
            withAnimation(.spring(duration: 0.32, bounce: 0.25)) {
                turns[card.id, default: 0] += adding ? 90 : -90
            }
        }
        Task {
            await desk.toggle(request.songs, in: card.id)
            try? await Task.sleep(for: .milliseconds(350))
            dismiss()
        }
    }
}
