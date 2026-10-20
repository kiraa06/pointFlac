import Foundation
import PFAudio
import PFCore
import PFSearch
import PFTestSupport
import Testing

@testable import PFLibrary

/// The path the app's adapter takes (contract 2): import → catalog → snapshot → search → queue.
@Test func importedMusicIsSearchableAndQueueable() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "LibraryToSearch-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(
        databaseURL: root.appending(path: "db.sqlite"), libraryFolder: root.appending(path: "Library"),
        artworkFolder: root.appending(path: "Artwork"))
    var picked: [URL] = []
    for (fixture, title, number) in [("s24-96000", "Señorita", 2), ("s16-44100", "Opening", 1)] {
        let url = root.appending(path: "Picked/\(title).flac")
        try TaggedFlac.write(
            fixture, to: url,
            tags: [
                ("TITLE", title), ("ARTIST", "Mónica Naranjo"), ("ALBUM", "Palabra de Mujer"),
                ("TRACKNUMBER", "\(number)"),
            ], picture: TaggedFlac.png())
        picked.append(url)
    }
    let result = await library.importFiles(picked)
    #expect(result.added.count == 2)

    let snapshot = await Task.detached { LibrarySnapshot(library.current) }.value
    let album = try #require(snapshot.search("monica palabra").albums.first)
    #expect(album.title == "Palabra de Mujer")
    let card = try #require(snapshot.album(album.id))
    #expect(card.formatLabel == "FLAC 24/96" && card.trackIDs.count == 2)
    #expect(library.artwork(card.artworkID) != nil)
    #expect(snapshot.tracks(of: album.id).map(\.title) == ["Opening", "Señorita"])

    let hit = try #require(snapshot.search("senor", filter: .hiRes24).tracks.first)
    #expect(String(hit.title[hit.titleHighlights[0]]) == "Señor")
    let items = snapshot.tracks(ids: [hit.id]).map { QueueItem(track: $0, artwork: library.artwork($0.artworkID)) }
    let item = try #require(items.first)
    #expect(item.id == hit.id && item.title == "Señorita" && item.artist == "Mónica Naranjo")
    #expect(item.format == AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2))
    #expect(item.totalFrames == 4096 && item.artwork != nil)
    #expect(FileManager.default.fileExists(atPath: item.url.path))
    #expect(snapshot.suggest("mon", limit: 3).first?.kind == .artist)
}
