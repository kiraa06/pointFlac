import Foundation
import Observation
import PFAudio
import PFCore
import PFFlac
import PFLibrary

/// The debug app's state: the library inbox and the player, wired to the real iOS audio stack.
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

    private let inbox: ImportInbox
    #if DEBUG
        private let preloadFixtures: Bool
    #endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let library = URL.documentsDirectory.appending(path: "Library", directoryHint: .isDirectory)
        // Created now rather than on the first import, so it shows in the Files app from the first launch. The inbox
        // creates it too, should this fail.
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        inbox = ImportInbox(libraryFolder: library)
        #if DEBUG
            preloadFixtures = arguments.contains("-PFPreloadFixtures")
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
    }

    /// Lists the library, after importing the bundled fixtures when asked to.
    func load() async {
        #if DEBUG
            if preloadFixtures {
                await importFiles(Self.bundledFixtures())
                return
            }
        #endif
        await reload()
    }

    func reload() async {
        files = await inbox.list()
    }

    /// Imports files picked in the Files picker (or the bundled fixtures), then lists the library again.
    func importFiles(_ urls: [URL]) async {
        let result = await inbox.importFiles(urls)
        rejections = result.rejected
        let skipped = urls.count - result.added.count - result.rejected.count
        importSummary =
            "Last import: \(result.added.count) added, \(skipped) already in the library, "
            + "\(result.rejected.count) not added"
        await reload()
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
