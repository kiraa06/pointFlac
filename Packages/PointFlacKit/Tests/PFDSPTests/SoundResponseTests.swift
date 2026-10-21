import Foundation
import Testing

@testable import PFDSP

@Suite("Sound response and headroom")
struct SoundResponseTests {
    private func settings(eq bands: [EQBand]) -> SoundSettings {
        var s = SoundSettings()
        s.pure = false
        s.eq = EQSettings(enabled: true, mode: .parametric, bands: bands)
        return s
    }

    @Test("a flat chain needs no headroom")
    func flatNeedsNoHeadroom() {
        var s = SoundSettings()
        s.pure = false
        s.eq = EQSettings(enabled: true, mode: .parametric, bands: [])
        #expect(SoundResponse.autoHeadroomDb(s, sampleRate: 44_100) == 0)
    }

    @Test("a +6 dB peak asks for 6 dB of headroom")
    func peakBoostIsCovered() {
        let s = settings(eq: [EQBand(type: .peak, frequency: 1000, gainDb: 6, q: 1)])
        let h = SoundResponse.autoHeadroomDb(s, sampleRate: 48_000)
        #expect(abs(h + 6) < 0.05)
    }

    @Test("overlapping boosts add before the peak is taken")
    func stackedBoostsAdd() {
        let s = settings(eq: [
            EQBand(type: .lowShelf, frequency: 250, gainDb: 4, q: 0.7),
            EQBand(type: .peak, frequency: 80, gainDb: 3, q: 1),
        ])
        #expect(SoundResponse.autoHeadroomDb(s, sampleRate: 48_000) <= -6.9)
    }

    @Test("cuts alone need no headroom")
    func cutsNeedNone() {
        let s = settings(eq: [
            EQBand(type: .peak, frequency: 1000, gainDb: -6, q: 1),
            EQBand(type: .highShelf, frequency: 8000, gainDb: -3, q: 0.7),
        ])
        #expect(SoundResponse.autoHeadroomDb(s, sampleRate: 48_000) == 0)
    }

    @Test("the curve is flat when Pure is on")
    func curveIsFlatWhenPure() {
        var s = settings(eq: [EQBand(type: .peak, frequency: 1000, gainDb: 6, q: 1)])
        s.pure = true
        let curve = SoundResponse.curveDb(s, sampleRate: 48_000)
        #expect(curve.count == 256)
        #expect(curve.allSatisfy { $0.db == 0 })
    }

    @Test("a notch keeps the curve finite")
    func notchStaysFinite() {
        let s = settings(eq: [EQBand(type: .notch, frequency: 1000, gainDb: 0, q: 5)])
        let curve = SoundResponse.curveDb(s, sampleRate: 48_000, points: 2048)
        #expect(curve.allSatisfy { $0.db.isFinite && $0.db >= -120 })
    }

    @Test("the correction preamp counts toward headroom, and disabled bands are skipped")
    func preampAndDisabledBands() {
        var s = settings(eq: [EQBand(type: .peak, frequency: 1000, gainDb: 6, q: 1, enabled: false)])
        s.correction = CorrectionSettings(enabled: true, preampDb: 3)
        #expect(abs(SoundResponse.autoHeadroomDb(s, sampleRate: 48_000) + 3) < 1e-9)
        #expect(SoundResponse.filters(s, sampleRate: 48_000).isEmpty)
    }

    @Test("the curve spans 20 Hz to just under Nyquist at low sample rates")
    func curveRange() {
        let curve = SoundResponse.curveDb(SoundSettings(), sampleRate: 8_000)
        #expect(curve.first?.hz == 20)
        #expect(abs((curve.last?.hz ?? 0) - 3_920) < 1e-6)
    }

    @Test("a narrow off-grid peak is found by the refinement, not just the grid scan")
    func narrowOffGridPeakIsRefined() {
        let fs = 48_000.0
        let s = settings(eq: [EQBand(type: .peak, frequency: 1234.5, gainDb: 24, q: 20)])
        let filter = SoundResponse.filters(s, sampleRate: fs)[0]
        // Brute force reference: a dense log scan, far finer than the 1024-point grid the implementation starts from.
        let n = 100_000
        let reference = (0..<n).map { i in
            filter.magnitudeDb(atHz: 20 * pow(1000.0, Double(i) / Double(n - 1)), sampleRate: fs)
        }.max()!
        #expect(reference > 20)
        #expect(abs(SoundResponse.autoHeadroomDb(s, sampleRate: fs) + reference) < 0.01)
    }
}
