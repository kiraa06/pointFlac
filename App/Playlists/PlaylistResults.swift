import PFDesign
import SwiftUI

extension PlaylistDesk {
    /// The playlists whose names match `query` as the shelf's search matches: from the start of a word, case and
    /// accents aside (spec §4: search results gain a "Playlists" section when names match).
    func playlists(matching query: String) -> [PlaylistCard] {
        let phrase = query.trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else { return [] }
        return playlists.filter { card in
            let name = card.name
            return name.indices.contains { index in
                (index == name.startIndex || name[name.index(before: index)].isWhitespace)
                    && name[index...].range(
                        of: phrase, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }
        }
    }
}

/// A playlist among the shelf's search results: its disc, its name (the match highlighted) and its song count. A tap
/// plays it (or opens it, empty); a hold offers Play Next, Add to Up Next and Open Playlist.
struct PlaylistResultRow: View {
    let card: PlaylistCard
    let desk: PlaylistDesk
    let theme: Theme
    /// The name, with the matching letters highlighted as the shelf highlights them.
    let title: AttributedString
    let play: () -> Void
    @Environment(\.playlistRouter) private var router

    var body: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                PressingDisc(look: card.look, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).lineLimit(1)
                    Text("Playlist · \(card.countText)").font(.caption).foregroundStyle(theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(theme.hairline.opacity(0.6)).frame(height: 0.5) }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                desk.playback.playNext(card.albumCard)
            }
            .disabled(card.songCount == 0)
            Button("Add to Up Next", systemImage: "text.append") { desk.playback.addToUpNext(card.albumCard) }
                .disabled(card.songCount == 0)
            Button("Open Playlist", systemImage: "music.note.list") { router.open(.open(card.id)) }
        }
        .accessibilityLabel(card.accessibilityLabel)
        // By ID: two playlists may share a name.
        .accessibilityIdentifier("result-playlist-\(card.id)")
    }
}
