import Foundation
import Observation
import PFAudio
import PFCore
import PFFlac
import PFLibrary

/// The app's state: the library inbox and the player, wired to the real iOS audio stack, plus (from Plan 3) the
/// protocol-typed library and music finder the UI codes against, and the playback controller over the player.
///
/// Plan 1's app is a debug harness for the audio core, so the model is deliberately thin. The library is whatever the
/// inbox lists from `Documents/Library`. Tapping a track plays that track alone, and Play All queues the whole
/// library. A tap does not queue the rest of the library after the track, because the fixtures last 85 ms: playback
/// would race through to the last one, and the strip, which keeps describing the last track played, would never show
/// the one tapped.
///
/// Launch arguments, both DEBUG only and ignored in Release builds:
/// - `-PFPreloadFixtures` imports the fixtures bundled under `Fixtures/` on launch (ruling R4).
/// - `-PFMuteOutput` puts the output in capture mode, which mutes the speaker, so UI tests play nothing aloud
///   (ruling R22).
@MainActor
@Observable
final class AppModel {
    /// The library, as the inbox last listed it.
    private(set) var files: [ImportedFile] = []
    /// What the latest import refused.
    private(set) var rejections: [ImportRejection] = []
    /// One line about the latest import, or why the picker failed.
    private(set) var importSummary: String?
    /// Builds its RemoteIO output when a start needs one: at the first play, and again after a media-services reset.
    /// Should that fail, the player's status says "Audio output unavailable: …", and the library still works.
    let player: Player

    /// What the Shelf browses and searches. `MockLibrary` over the inbox until the controller swaps in stream A's.
    @ObservationIgnored private(set) var library: any LibraryBrowsing
    /// Get Music and Downloads. `MockMusicFinder` until the controller swaps in the real providers.
    @ObservationIgnored private(set) var finder: any MusicFinding
    /// The record on the deck, its sides, Up Next and repeat.
    @ObservationIgnored private(set) var playback: PlaybackController

    private let inbox: ImportInbox
    #if DEBUG
        private let preloadFixtures: Bool
        /// `-PFDemoPlay`: plays the demo album "Night Drive" once the library is listed, for screenshots and UI tests.
        private let demoPlay: Bool
    #endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let folder = URL.documentsDirectory.appending(path: "Library", directoryHint: .isDirectory)
        // Created now rather than on the first import, so it shows in the Files app from the first launch. The inbox
        // creates it too, should this fail.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        inbox = ImportInbox(libraryFolder: folder)
        #if DEBUG
            preloadFixtures = arguments.contains("-PFPreloadFixtures")
            demoPlay = arguments.contains("-PFDemoPlay")
            let mute = arguments.contains("-PFMuteOutput")
        #endif
        player = Player(
            session: SystemAudioSession(),
            makeOutput: {
                let output = try RemoteIOOutput()
                #if DEBUG
                    if mute {
                        // Every output the player builds is muted. The capture only has to exist for the mute; what it
                        // records is never read here.
                        output.installCapture(byteCapacity: 4096)
                    }
                #endif
                return output
            },
            capabilities: .current, nowPlaying: SystemNowPlaying(), makeDecoder: { try FlacDecoder(url: $0.url) })
        let mock = MockLibrary()
        library = mock
        finder = MockMusicFinder(library: mock)
        playback = PlaybackController(player: player, library: mock)
        mock.importer = { [weak self] urls in await self?.importFiles(urls) }
    }

    /// Swaps in other implementations of the UI's contracts: the controller's adapters at integration.
    func use(library: any LibraryBrowsing, finder: any MusicFinding) {
        self.library = library
        self.finder = finder
        playback = PlaybackController(player: player, library: library)
    }

    /// Lists the library, after importing the bundled fixtures when asked to.
    func load() async {
        #if DEBUG
            if preloadFixtures {
                await importFiles(Self.bundledFixtures())
            } else {
                await reload()
            }
            if demoPlay, let album = library.albums.first(where: { $0.title == "Night Drive" }) ?? library.albums.first
            {
                await playback.load(album)
            }
        #else
            await reload()
        #endif
    }

    func reload() async {
        files = await inbox.list()
        (library as? MockLibrary)?.update(from: files)
    }

    /// Imports files picked in the Files picker (or the bundled fixtures), then lists the library again.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> (added: Int, rejected: [String]) {
        let result = await inbox.importFiles(urls)
        rejections = result.rejected
        let skipped = urls.count - result.added.count - result.rejected.count
        importSummary =
            "Last import: \(result.added.count) added, \(skipped) already in the library, "
            + "\(result.rejected.count) not added"
        await reload()
        return (result.added.count, result.rejected.map { "\($0.fileName): \($0.message)" })
    }

    func importFailed(_ error: any Error) {
        importSummary = "The picker failed: \(error.localizedDescription)"
    }

    /// Plays `file` alone, if v1 can play it.
    func play(_ file: ImportedFile) async {
        guard file.isSupported else { return }
        await player.play([QueueItem(file)], startingAt: 0)
    }

    /// Plays the whole library, in order, from the first track, leaving out what v1 cannot play (multichannel files,
    /// which would only fail one by one).
    func playAll() async {
        await player.play(files.filter(\.isSupported).map { QueueItem($0) }, startingAt: 0)
    }

    #if DEBUG
        /// The fixtures in the app bundle's `Fixtures` folder, which only Debug builds carry (ruling R4).
        private static func bundledFixtures() -> [URL] {
            let urls = Bundle.main.urls(forResourcesWithExtension: "flac", subdirectory: "Fixtures") ?? []
            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    #endif
}

extension ImportedFile {
    /// The file name without its extension. Unique in the library, unlike the title (ruling R20).
    var stem: String {
        (id as NSString).deletingPathExtension
    }
}

extension QueueItem {
    init(_ file: ImportedFile) {
        self.init(
            id: file.id, url: file.url, title: file.title, artist: file.artist, album: file.album, format: file.format,
            totalFrames: file.totalFrames)
    }
}
