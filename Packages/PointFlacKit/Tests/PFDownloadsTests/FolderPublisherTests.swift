import Foundation
import Synchronization
import Testing

@testable import PFDownloads

/// The publish step's decisions, with every outside step (the folder, the library, the app's import) faked: a download
/// is never lost, the staged file goes only once the song is safe somewhere, only the folder's own faults make it
/// unavailable, and one download's trouble falls back for that download alone.
@Suite("FolderPublisher")
struct FolderPublisherTests {
    static let staged = URL(filePath: "/staging/job/01 Fold.flac")
    static let folder = URL(filePath: "/iCloud/pointFlac", directoryHint: .isDirectory)
    static let choice = UUID()
    static let track = RemoteTrack(
        id: "t1", provider: "archive", title: "Fold", artist: "Ada Vale", album: "Paper Moons", fileName: "01 Fold.flac"
    )
    static var savedURL: URL { folder.appending(path: "Ada Vale/Paper Moons/01 Fold.flac") }

    /// Scripted outside steps, recording the order they ran in.
    final class World: Sendable {
        let events = Mutex<[String]>([])
        let marked = Mutex<[UUID]>([])
        let target = Mutex(DownloadTarget.folder(FolderPublisherTests.choice))
        let openFault = Mutex<DownloadDestination.Failure?>(nil)
        let reads = Mutex([true])
        let addFails = Mutex(false)
        let saveFault = Mutex<DownloadDestination.Failure?>(nil)
        let savedIsNew = Mutex(true)
        let admitted = Mutex<String?>("track-1")
        let admitThrows = Mutex(false)
        let catalogHas = Mutex(true)
        let importFails = Mutex(false)
        let importedID = Mutex<String?>("app-track")
        let saveGate = Mutex<Gate?>(nil)

        func log(_ event: String) { events.withLock { $0.append(event) } }
        var log: [String] { events.withLock { $0 } }

        var steps: FolderPublisher.Steps {
            FolderPublisher.Steps(
                target: { self.target.withLock { $0 } },
                markUnavailable: { id in self.marked.withLock { $0.append(id) } },
                open: {
                    self.log("open")
                    if let fault = self.openFault.withLock({ $0 }) { throw fault }
                    return OpenedFolder(url: FolderPublisherTests.folder) { self.log("close") }
                },
                libraryReads: { _ in
                    self.log("reads")
                    return self.reads.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
                },
                addToLibrary: { _ in
                    self.log("add")
                    if self.addFails.withLock({ $0 }) { throw CocoaError(.fileReadUnknown) }
                },
                save: { _, track, _ in
                    self.log("save \(track.artist ?? "")")
                    if let gate = self.saveGate.withLock({ $0 }) { await gate.wait() }
                    if let fault = self.saveFault.withLock({ $0 }) { throw fault }
                    return DownloadDestination.Saved(
                        url: FolderPublisherTests.savedURL, isNew: self.savedIsNew.withLock { $0 })
                },
                admit: { _ in
                    self.log("admit")
                    if self.admitThrows.withLock({ $0 }) { throw CocoaError(.fileReadUnknown) }
                    return self.admitted.withLock { $0 }
                },
                inCatalog: { _ in
                    self.log("catalog")
                    return self.catalogHas.withLock { $0 }
                },
                takeBack: { saved in self.log("takeBack \(saved.isNew)") },
                importIntoApp: { _ in
                    self.log("import")
                    if self.importFails.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                    return self.importedID.withLock { $0 }
                },
                deleteStaged: { _ in self.log("deleteStaged") })
        }
    }

    @Test("saved to the folder: the staged file goes only after the catalog has the song, then the scope closes")
    func success() async throws {
        let world = World()
        let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note
        #expect(note == nil)
        #expect(world.log == ["open", "reads", "save Ada Vale", "admit", "catalog", "deleteStaged", "close"])
        #expect(world.marked.withLock { $0 }.isEmpty)
    }

    enum AdmitFault: CaseIterable, Sendable { case refused, threw, missingFromCatalog }

    @Test(
        "the library can't take the copy: ours is taken back, the app imports it, the staged file goes after that",
        arguments: AdmitFault.allCases)
    func admitFailure(fault: AdmitFault) async throws {
        let world = World()
        switch fault {
        case .refused: world.admitted.withLock { $0 = nil }
        case .threw: world.admitThrows.withLock { $0 = true }
        case .missingFromCatalog: world.catalogHas.withLock { $0 = false }
        }
        let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note

        #expect(note == FolderPublisher.notAdmittedNote)
        let log = world.log
        #expect(log.contains("takeBack true"))
        let importAt = try #require(log.firstIndex(of: "import"))
        let deleteAt = try #require(log.firstIndex(of: "deleteStaged"))
        #expect(importAt < deleteAt)
        #expect(log.firstIndex(of: "takeBack true")! < importAt)
        #expect(log.filter { $0 == "deleteStaged" }.count == 1)
        // The folder is fine; only this file had trouble.
        #expect(world.marked.withLock { $0 }.isEmpty)
    }

    @Test("an identical file that was already there is never taken back")
    func adoptedFileIsKept() async throws {
        let world = World()
        world.savedIsNew.withLock { $0 = false }
        world.admitted.withLock { $0 = nil }
        _ = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track)
        #expect(world.log.contains("takeBack false") || !world.log.contains { $0.hasPrefix("takeBack") })
        #expect(!world.log.contains("takeBack true"))
    }

    @Test("a folder the library does not read is added first, then the song saved there")
    func libraryAddsTheFolderFirst() async throws {
        let world = World()
        world.reads.withLock { $0 = [false, true] }
        let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note
        #expect(note == nil)
        #expect(world.log.prefix(4) == ["open", "reads", "add", "reads"])
        #expect(world.log.contains("deleteStaged"))
    }

    @Test("a folder the library still can't read: nothing is copied, the app imports it, the folder stays chosen")
    func libraryNotReadingTheFolder() async throws {
        let world = World()
        world.reads.withLock { $0 = [false] }
        world.addFails.withLock { $0 = true }
        let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note
        #expect(note == FolderPublisher.notReadNote)
        #expect(!world.log.contains { $0.hasPrefix("save") })
        #expect(world.log.suffix(2) == ["import", "deleteStaged"])
        #expect(world.marked.withLock { $0 }.isEmpty)
    }

    @Test("a folder already known unavailable is not tried: the app imports it, and the row says why")
    func alreadyUnavailable() async throws {
        let world = World()
        world.target.withLock { $0 = .unavailable }
        let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note
        #expect(note == FolderPublisher.unavailableNote)
        #expect(world.log == ["import", "deleteStaged"])
    }

    @Test("with no folder chosen the app imports it, as before, and the row just says Done")
    func inTheApp() async throws {
        let world = World()
        world.target.withLock { $0 = .app }
        let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note
        #expect(note == nil)
        #expect(world.log == ["import", "deleteStaged"])
    }

    @Test("one download's trouble in the folder falls back for that download only: the folder stays chosen")
    func fileOnlyFailureDoesNotMark() async throws {
        let world = World()
        world.saveFault.withLock { $0 = .fileOnly("a file is in the way of its folder") }
        let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note
        #expect(note == "Saved in pointFlac (a file is in the way of its folder)")
        #expect(world.marked.withLock { $0 }.isEmpty)
        #expect(world.log.suffix(2) == ["import", "deleteStaged"])
    }

    @Test("the folder's own fault (gone, refused, full) marks it unavailable, by the choice's identity")
    func unreachableMarks() async throws {
        for fault in ["open", "save"] {
            let world = World()
            let failure = DownloadDestination.Failure.unreachable("there's no space left")
            if fault == "open" { world.openFault.withLock { $0 = failure } }
            if fault == "save" { world.saveFault.withLock { $0 = failure } }
            let note = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track).note
            #expect(note == FolderPublisher.unavailableNote)
            #expect(world.marked.withLock { $0 } == [Self.choice])
            #expect(world.log.suffix(2) == ["import", "deleteStaged"])
        }
    }

    @Test("the app's import failing too fails the job, with the staged file kept for a retry")
    func importFailsAfterTheFolderFailed() async throws {
        let world = World()
        world.saveFault.withLock { $0 = .unreachable("the folder is not there") }
        world.importFails.withLock { $0 = true }
        await #expect(throws: CocoaError.self) {
            try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track)
        }
        #expect(!world.log.contains("deleteStaged"))
        #expect(world.marked.withLock { $0 } == [Self.choice])
    }

    @Test("saved to the folder, the publication names the track the library admitted there")
    func folderPathReportsTheAdmittedTrack() async throws {
        let world = World()
        let published = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track)
        #expect(published == Publication(note: nil, trackID: "track-1"))
    }

    @Test("imported into the app (chosen, known unavailable, or as a fallback), it names the import's track")
    func appPathReportsTheImportedTrack() async throws {
        for setup in ["app", "unavailable", "fallback"] {
            let world = World()
            switch setup {
            case "app": world.target.withLock { $0 = .app }
            case "unavailable": world.target.withLock { $0 = .unavailable }
            default: world.saveFault.withLock { $0 = .fileOnly("a file is in the way of its folder") }
            }
            let published = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track)
            #expect(published.trackID == "app-track", "\(setup)")
        }
        // An import that kept the file but could not name its track still finishes the download.
        let world = World()
        world.target.withLock { $0 = .app }
        world.importedID.withLock { $0 = nil }
        let published = try await FolderPublisher(steps: world.steps).publish(Self.staged, track: Self.track)
        #expect(published == Publication(note: nil, trackID: nil))
    }

    @Test("downloads go into the folder one at a time, so one can never adopt a copy another may take back")
    func oneAtATime() async throws {
        let world = World()
        let gate = Gate()
        world.saveGate.withLock { $0 = gate }
        let publisher = FolderPublisher(steps: world.steps)
        async let first = publisher.publish(Self.staged, track: Self.track)
        try await Task.sleep(for: .milliseconds(100))
        async let second = publisher.publish(Self.staged, track: Self.track)
        try await Task.sleep(for: .milliseconds(100))
        // The second has not opened the folder while the first is still saving.
        #expect(world.log == ["open", "reads", "save Ada Vale"])
        await gate.open()
        _ = try await (first, second)
        #expect(world.log.filter { $0 == "open" }.count == 2)
        #expect(world.log.firstIndex(of: "close")! < world.log.lastIndex(of: "open")!)
    }
}
