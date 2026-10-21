import Foundation
import Testing

@testable import PFDSP

/// The bundled OPRA presets (`App/Resources/OPRA/opra.json`, written by `scripts/build-opra.swift`) as headphone
/// corrections.
@Suite("OPRA presets")
struct OPRAPresetTests {
    /// AKG K553 by oratory1990, verbatim from the shipped file: one of the 24 presets with a band below the chain's
    /// 20 Hz floor (a peak at 15 Hz).
    static let k553 = """
        {"author":"oratory1990","bands":[{"fc":15,"gain":-11,"q":0.25,"type":"peak"},{"fc":105,"gain":5.5,"q":0.71,\
        "type":"lowShelf"},{"fc":110,"gain":-4.7,"q":1.4,"type":"peak"},{"fc":235,"gain":-2.9,"q":0.7,"type":"peak"},\
        {"fc":1250,"gain":-1.3,"q":2,"type":"peak"},{"fc":2770,"gain":-4,"q":3,"type":"peak"},{"fc":4100,"gain":4.7,\
        "q":0.7,"type":"peak"},{"fc":5400,"gain":-7.4,"q":4,"type":"peak"},{"fc":7550,"gain":-3.4,"q":5,"type":"peak"},\
        {"fc":10000,"gain":-1,"q":0.71,"type":"highShelf"}],"details":"Harman Target",\
        "id":"akg:k553::oratory1990_harman_target","preampDb":-3,"product":"K553","vendor":"AKG"}
        """

    @Test("a preset becomes a switched-on correction that credits its author")
    func correction() throws {
        let preset = try #require(try OPRAPreset.catalog(from: Data("[\(Self.k553)]".utf8)).first)
        #expect(preset.displayName == "AKG K553")
        #expect(preset.details == "Harman Target")
        let c = preset.correction
        #expect(c.enabled)
        #expect(c.name == "AKG K553")
        #expect(c.author == "oratory1990")
        #expect(c.source == .opra(id: "akg:k553::oratory1990_harman_target"))
        #expect(c.preampDb == -3)
        #expect(c.bands.count == 10)
        #expect(c.bands[1] == EQBand(type: .lowShelf, frequency: 105, gainDb: 5.5, q: 0.71))
    }

    @Test("a band below 20 Hz loads, and clamping puts it at the floor without touching the others")
    func subsonicBandIsClamped() throws {
        let preset = try #require(try OPRAPreset.catalog(from: Data("[\(Self.k553)]".utf8)).first)
        #expect(preset.correction.bands[0].frequency == 15)
        var s = SoundSettings()
        s.pure = false
        s.correction = preset.correction
        let clamped = s.clamped()
        #expect(clamped.correction.bands[0] == EQBand(type: .peak, frequency: 20, gainDb: -11, q: 0.25))
        #expect(Array(clamped.correction.bands.dropFirst()) == Array(preset.correction.bands.dropFirst()))
        // It compiles and draws: finite gain, filters and curve.
        let chain = SoundChain(s, sampleRate: 44_100, channels: 2)
        #expect(chain.preampDb.isFinite)
        #expect(SoundResponse.filters(s, sampleRate: 44_100).count == 10)
        #expect(SoundResponse.curveDb(s, sampleRate: 44_100).allSatisfy { $0.db.isFinite })
    }

    @Test("a product already named after its vendor is not named twice, and missing details read as none")
    func naming() throws {
        let json = """
            [{"author":"a","bands":[{"fc":100,"gain":1,"q":1,"type":"peak"}],"id":"x","preampDb":0,\
            "product":"Sony WH-1000XM4","vendor":"Sony"}]
            """
        let preset = try #require(try OPRAPreset.catalog(from: Data(json.utf8)).first)
        #expect(preset.displayName == "Sony WH-1000XM4")
        #expect(preset.details == "")
    }

    @Test("a band type the chain cannot run fails the load rather than being guessed")
    func unknownType() {
        let json = """
            [{"author":"a","bands":[{"fc":100,"gain":1,"q":1,"type":"bandPass"}],"details":"","id":"x",\
            "preampDb":0,"product":"P","vendor":"V"}]
            """
        #expect(throws: (any Error).self) { try OPRAPreset.catalog(from: Data(json.utf8)) }
    }

    /// The file the app bundles, read from the repository. Skipped where the repository is out of reach (a device).
    static let shipped = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/Resources/OPRA/opra.json")

    @Test(
        "every shipped preset loads and clamps into the chain's ranges",
        .enabled(if: FileManager.default.isReadableFile(atPath: shipped.path)))
    func shippedFile() throws {
        let presets = try OPRAPreset.catalog(from: Data(contentsOf: Self.shipped))
        #expect(presets.count > 1000)
        #expect(Set(presets.map(\.id)).count == presets.count)
        var below = 0
        for preset in presets {
            below += preset.bands.filter { $0.fc < 20 }.count
            var s = SoundSettings()
            s.pure = false
            s.correction = preset.correction
            let bands = s.clamped().correction.bands
            #expect(bands.count == preset.bands.count && bands.count <= AutoEqParser.maxBands, "\(preset.id)")
            #expect(
                bands.allSatisfy { (20...20_000).contains($0.frequency) && (0.1...20).contains($0.q) },
                "\(preset.id)")
            #expect(preset.preampDb.isFinite && !preset.author.isEmpty, "\(preset.id)")
        }
        // The build script's count of bands below the floor, which clamping lifts to 20 Hz.
        #expect(below == 24)
    }
}
