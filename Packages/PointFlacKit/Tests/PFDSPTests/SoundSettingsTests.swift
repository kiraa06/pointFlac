import Foundation
import Testing

@testable import PFDSP

@Suite("Sound settings model")
struct SoundSettingsTests {
    @Test("defaults are Pure with no active blocks")
    func defaultsArePure() {
        let s = SoundSettings()
        #expect(s.pure == true)
        #expect(s.activeBlockNames.isEmpty)
    }

    @Test("a fully populated value round-trips through JSON")
    func roundTrips() throws {
        var s = SoundSettings()
        s.pure = false
        s.replayGain = ReplayGainSettings(
            mode: .album, preampDb: 3, preventClipping: false, referenceLufs: -16)
        s.preamp = PreampSettings(autoHeadroom: false, trimDb: -4)
        s.correction = CorrectionSettings(
            enabled: true, name: "HD 600", author: "oratory1990", source: .opra(id: "abc"),
            preampDb: -5.5,
            bands: [EQBand(type: .peak, frequency: 1000, gainDb: 2, q: 1)])
        s.eq = EQSettings(
            enabled: true, mode: .parametric, graphicGainsDb: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            bands: [EQBand(type: .lowShelf, frequency: 80, gainDb: 3, q: 0.7, enabled: false)],
            presetName: "Vocal")
        s.tone = ToneSettings(enabled: true, bassDb: 2, trebleDb: -1, tiltDb: 1)
        s.crossfeed = CrossfeedSettings(enabled: true, preset: .janMeier)
        s.limiter = LimiterSettings(ceilingDbTP: -1)
        s.crossfade = CrossfadeSettings(mode: .always, seconds: 8)
        let data = try JSONEncoder().encode(s)
        #expect(SoundSettings.decode(data) == s)
        var t = s
        t.correction.source = .autoEq(fileName: "x.txt")
        #expect(SoundSettings.decode(try JSONEncoder().encode(t)) == t)
        t.correction.source = CorrectionSource.none
        #expect(SoundSettings.decode(try JSONEncoder().encode(t)) == t)
    }

    @Test("clamping applies every range")
    func clampsEverything() {
        var s = SoundSettings()
        s.eq.bands = (0..<25).map { _ in EQBand(type: .peak, frequency: 1000, gainDb: 0, q: 1) }
        s.eq.bands[0].gainDb = 40
        s.eq.bands[1].frequency = 5
        s.eq.bands[2].q = 50
        s.crossfade.seconds = 30
        let c = s.clamped()
        #expect(c.eq.bands.count == 20)
        #expect(c.eq.bands[0].gainDb == 24)
        #expect(c.eq.bands[1].frequency == 20)
        #expect(c.eq.bands[2].q == 20)
        #expect(c.crossfade.seconds == 12)
    }

    @Test("block names follow the chain order and Limiter joins when anything is on")
    func blockNamesFollowTheChain() {
        var s = SoundSettings()
        s.pure = false
        s.eq.enabled = true
        s.tone.enabled = true
        #expect(s.activeBlockNames == ["EQ", "Tone", "Limiter"])
        s.pure = true
        #expect(s.activeBlockNames.isEmpty)
    }

    @Test("graphic mode maps to ten peaks at ISO centres")
    func graphicMapsToTenPeaks() {
        var e = EQSettings()
        e.graphicGainsDb[3] = 20
        let b = e.effectiveBands
        #expect(b.count == 10)
        #expect(b.map(\.frequency) == [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
        #expect(b.allSatisfy { $0.type == .peak && $0.q == 1.41 })
        #expect(b[3].gainDb == 12)
    }

    @Test("tilt is a pair of opposing shelves at 1 kHz")
    func tiltIsAPairOfShelves() {
        let t = ToneSettings(enabled: true, bassDb: 0, trebleDb: 0, tiltDb: 4)
        let shelves = t.effectiveBands.filter { $0.frequency == 1000 }
        #expect(shelves.count == 2)
        #expect(shelves.first { $0.type == .lowShelf }?.gainDb == -2)
        #expect(shelves.first { $0.type == .highShelf }?.gainDb == 2)
        #expect(shelves.allSatisfy { $0.q == 0.5 })
    }

    @Test("unknown JSON falls back to Pure defaults")
    func unknownJSONFallsBackToPure() {
        let data = Data(#"{"pure":false,"eq":{"mode":"bogus"}}"#.utf8)
        #expect(SoundSettings.decode(data) == SoundSettings())
    }

    @Test("crossfeed presets carry their cut and feed")
    func crossfeedPresetValues() {
        #expect(CrossfeedPreset.defaultBS2B.parameters == (700, 4.5))
        #expect(CrossfeedPreset.chuMoy.parameters == (700, 6.0))
        #expect(CrossfeedPreset.janMeier.parameters == (650, 9.5))
    }
}
