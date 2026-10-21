import Foundation
import Observation
import PFAudio
import PFCore
import PFFlac
import PFLibrary

/// The app's state: the player, wired to the real iOS audio stack; the library (stream A's `Library`, through
/// `RealLibrary`); the music finder (the real providers, through `RealMusicFinder`); and the playback controller.
///
/// There is one library over `Documents/Library`, and so one import inbox: `Library` owns it. Diagnostics (Plan 1's
/// debug views) reads the same library rather than a second inbox, since two inboxes over one folder would race.
///
/// Launch arguments, all DEBUG only and ignored in Release builds:
/// - `-PFPreloadFixtures` imports the fixtures bundled under `Fixtures/` on launch (ruling R4).
/// - `-PFMuteOutput` puts the output in capture mode, which mutes the speaker, so UI tests play nothing aloud
///   (ruling R22).
/// - `-PFMockFinder`, and `-PFPreloadFixtures` too, keep the demo `MockMusicFinder`, so UI tests never touch the
///   network and stay deterministic.
@MainActor
@Observable
final class AppModel {
    /// What the latest import refused.
    private(set) var rejections: [ImportRejection] = []
    /// One line about the latest import, or why the picker failed.
    private(set) var importSummary: String?
    /// Builds its RemoteIO output when a start needs one: at the first play, and again after a media-services reset.
    /// Should that fail, the player's status says "Audio output unavailable: …", and the library still works.
    let player: Player

    /// What the Shelf browses and searches. Set once, before the UI mounts (so not observed).
    @ObservationIgnored let library: any LibraryBrowsing
    /// Get Music and Downloads. Set once, before the UI mounts.
    @ObservationIgnored let finder: any MusicFinding
    /// The record on the deck, its sides, Up Next and repeat. Set once, before the UI mounts.
    @ObservationIgnored let playback: PlaybackController
    /// The real library behind `library`.
    let realLibrary: RealLibrary
    /// The real finder, unless a DEBUG launch asked for the mock.
    @ObservationIgnored let realFinder: RealMusicFinder?
    #if SOULSEEK
        /// The one Soulseek session (Settings → Soulseek).
        let soulseek: SoulseekAccount
    #endif

    #if DEBUG
        private let preloadFixtures: Bool
        /// `-PFDemoPlay`: plays the demo album "Night Drive" once the library is listed, for screenshots and UI tests.
        private let demoPlay: Bool
    #endif

    /// Settings keys for the privacy switches (spec §5.8): MusicBrainz name lookups on by default (ruling R26),
    /// artwork lookups off.
    static let lookupNamesKey = "lookupNamesOnline"
    static let lookupArtworkKey = "lookupArtworkOnline"

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        UserDefaults.standard.register(defaults: [Self.lookupNamesKey: true, Self.lookupArtworkKey: false])
        let realLibrary = RealLibrary(library: Self.openLibrary())
        self.realLibrary = realLibrary
        #if DEBUG
            preloadFixtures = arguments.contains("-PFPreloadFixtures")
            demoPlay = arguments.contains("-PFDemoPlay")
            let mute = arguments.contains("-PFMuteOutput")
            let useMock = preloadFixtures || arguments.contains("-PFMockFinder")
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
        let names = UserDefaults.standard.bool(forKey: Self.lookupNamesKey)
        let artwork = UserDefaults.standard.bool(forKey: Self.lookupArtworkKey)
        #if SOULSEEK
            let soulseek = SoulseekAccount()
            self.soulseek = soulseek
            let makeReal = {
                RealMusicFinder(
                    library: realLibrary, soulseek: soulseek.client, registryEnabled: names, artworkEnabled: artwork)
            }
        #else
            let makeReal = {
                RealMusicFinder(library: realLibrary, registryEnabled: names, artworkEnabled: artwork)
            }
        #endif
        library = realLibrary
        #if DEBUG
            // The demo finder exists only in Debug builds, and only under the UI tests' launch arguments.
            if useMock {
                realFinder = nil
                finder = MockMusicFinder(library: realLibrary)
            } else {
                let real = makeReal()
                realFinder = real
                finder = real
            }
        #else
            let real = makeReal()
            realFinder = real
            finder = real
        #endif
        playback = PlaybackController(player: player, library: realLibrary)
    }

    /// The library database and covers live in Application Support (never Caches, which the system purges; the
    /// library refuses it). Should the database not open, a temporary one keeps the app usable, and the next launch
    /// tries the real one again.
    private static func openLibrary() -> Library {
        let folder = URL.documentsDirectory.appending(path: "Library", directoryHint: .isDirectory)
        // Created now rather than on the first import, so it shows in the Files app from the first launch.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for base in [URL.applicationSupportDirectory, FileManager.default.temporaryDirectory] {
            let root = base.appending(path: "PointFlacLibrary", directoryHint: .isDirectory)
            let artwork = root.appending(path: "Artwork", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
            if let library = try? Library(
                databaseURL: root.appending(path: "library.sqlite"), libraryFolder: folder, artworkFolder: artwork)
            {
                return library
            }
        }
        fatalError("pointFlac could not open a library database in Application Support or the temporary folder")
    }

    /// The privacy switches changed in Settings: applied at once.
    func lookupsChanged() {
        realFinder?.setLookups(
            registry: UserDefaults.standard.bool(forKey: Self.lookupNamesKey),
            artwork: UserDefaults.standard.bool(forKey: Self.lookupArtworkKey))
    }

    /// Starts the library and the download queue, and lists the library, after importing the bundled fixtures when
    /// asked to.
    func load() async {
        realLibrary.start()
        if let realFinder { Task { await realFinder.start() } }
        #if SOULSEEK
            if realFinder != nil { Task { await soulseek.resume() } }
        #endif
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

    /// Rescans the library folders: at launch, on pull-to-refresh and when the app returns to the foreground.
    func reload() async {
        await realLibrary.rescan()
    }

    /// Every track in the library, for Diagnostics.
    var files: [LibraryTrack] {
        Array(realLibrary.snapshot.catalog.tracks.values)
    }

    /// Imports files picked in the Files picker (or the bundled fixtures) into the library.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> (added: Int, rejected: [String]) {
        let result = await realLibrary.library.importFiles(urls)
        await realLibrary.sync()
        rejections = result.rejected
        importSummary =
            "Last import: \(result.added.count) added, \(result.duplicates) already in the library, "
            + "\(result.rejected.count) not added" + (result.error.map { ". Library error: \($0)" } ?? "")
        var lines = result.rejected.map { "\($0.fileName): \($0.message)" }
        if let error = result.error { lines.append("Library: \(error)") }
        return (result.added.count, lines)
    }

    func importFailed(_ error: any Error) {
        importSummary = "The picker failed: \(error.localizedDescription)"
    }

    /// Plays `track` alone, if v1 can play it.
    func play(_ track: LibraryTrack) async {
        guard track.isSupported else { return }
        await player.play(
            [QueueItem(track: track, artwork: realLibrary.library.artwork(track.artworkID))], startingAt: 0)
    }

    /// Plays the whole library, in Diagnostics order, leaving out what v1 cannot play (multichannel files, which would
    /// only fail one by one).
    func playAll() async {
        let tracks = files.filter(\.isSupported).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        await player.play(tracks.map { QueueItem(track: $0) }, startingAt: 0)
    }

    #if DEBUG
        /// The fixtures in the app bundle's `Fixtures` folder, which only Debug builds carry (ruling R4).
        private static func bundledFixtures() -> [URL] {
            let urls = Bundle.main.urls(forResourcesWithExtension: "flac", subdirectory: "Fixtures") ?? []
            return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    #endif
}

extension LibraryTrack {
    /// The file name without its extension: unique in the library folder, unlike the title (ruling R20).
    var stem: String {
        url.deletingPathExtension().lastPathComponent
    }
}
