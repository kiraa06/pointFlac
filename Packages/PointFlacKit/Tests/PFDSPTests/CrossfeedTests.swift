import Foundation
import Testing

@testable import PFDSP

/// Steady-state RMS of both channels for a sine fed to the left channel only (or to both, for `mono`).
private func levels(
    preset: CrossfeedPreset, hz: Double, mono: Bool = false, sampleRate: Double = 48_000
) -> (left: Double, right: Double) {
    var crossfeed = Crossfeed(preset: preset, sampleRate: sampleRate)
    let total = Int(sampleRate)  // one second; the first half settles the filters
    var sumL = 0.0
    var sumR = 0.0
    var counted = 0
    for n in 0..<total {
        let x = sin(2 * Double.pi * hz * Double(n) / sampleRate)
        var l = x
        var r = mono ? x : 0
        crossfeed.process(left: &l, right: &r)
        if n >= total / 2 {
            sumL += l * l
            sumR += r * r
            counted += 1
        }
    }
    return ((sumL / Double(counted)).squareRoot(), (sumR / Double(counted)).squareRoot())
}

private func db(_ ratio: Double) -> Double { 20 * log10(ratio) }

@Suite("Crossfeed")
struct CrossfeedTests {
    @Test(arguments: CrossfeedPreset.allCases)
    func monoStaysCentred(preset: CrossfeedPreset) {
        var crossfeed = Crossfeed(preset: preset, sampleRate: 44_100)
        for n in 0..<4_000 {
            var l = sin(Double(n) * 0.05) * 0.7 + sin(Double(n) * 0.9) * 0.2
            var r = l
            crossfeed.process(left: &l, right: &r)
            #expect(l == r)
        }
    }

    @Test(arguments: CrossfeedPreset.allCases)
    func bassBleedsAcross(preset: CrossfeedPreset) {
        let out = levels(preset: preset, hz: 100)
        let relative = db(out.right / out.left)
        #expect(abs(relative - -preset.parameters.feedDb) < 1.0, "\(preset): \(relative) dB")
    }

    @Test(arguments: CrossfeedPreset.allCases)
    func trebleStaysApart(preset: CrossfeedPreset) {
        let out = levels(preset: preset, hz: 10_000)
        let relative = db(out.right / out.left)
        #expect(relative < -20, "\(preset): \(relative) dB")
    }

    /// bs2b normalises the bass: `gain` makes the mono sum unity at low frequencies. It is not flat above that: the
    /// low-pass cross path rolls off, so the mono sum dips by about 1 dB at 1 kHz (the brief's "< 0.5 dB at 1 kHz" does
    /// not hold for libbs2b itself).
    @Test(arguments: CrossfeedPreset.allCases)
    func bassLevelPreserved(preset: CrossfeedPreset) {
        let out = levels(preset: preset, hz: 100, mono: true)
        let change = db(out.left / (1 / 2.0.squareRoot()))
        #expect(abs(change) < 0.5, "\(preset): \(change) dB")
    }

    /// Mono-sum change at 1 kHz as measured from libbs2b 3.1.0's own `bs2b_cross_feed_d` at 48 kHz.
    @Test(arguments: [
        (CrossfeedPreset.defaultBS2B, -1.394), (.chuMoy, -1.193), (.janMeier, -0.899),
    ])
    func midLevelMatchesLibbs2b(preset: CrossfeedPreset, referenceDb: Double) {
        let out = levels(preset: preset, hz: 1_000, mono: true)
        let change = db(out.left / (1 / 2.0.squareRoot()))
        #expect(abs(change - referenceDb) < 0.02, "\(preset): \(change) dB")
    }

    @Test(arguments: [44_100.0, 96_000.0, 192_000.0])
    func bassBleedHoldsAcrossSampleRates(sampleRate: Double) {
        let out = levels(preset: .defaultBS2B, hz: 100, sampleRate: sampleRate)
        #expect(abs(db(out.right / out.left) - -4.5) < 1.0)
    }

    @Test func silentTailDecaysWithoutDenormals() {
        var crossfeed = Crossfeed(preset: .janMeier, sampleRate: 48_000)
        var l = 1.0
        var r = -0.5
        crossfeed.process(left: &l, right: &r)
        for _ in 0..<200_000 {
            l = 0
            r = 0
            crossfeed.process(left: &l, right: &r)
            #expect(l == 0 || abs(l) >= Double.leastNormalMagnitude)
            #expect(r == 0 || abs(r) >= Double.leastNormalMagnitude)
        }
        #expect(l == 0 && r == 0)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteInputRecovers(bad: Double) {
        var crossfeed = Crossfeed(preset: .defaultBS2B, sampleRate: 48_000)
        var l = bad
        var r = 0.25
        crossfeed.process(left: &l, right: &r)
        #expect(l.isFinite && r.isFinite)
        // A tone afterwards comes through as if the bad sample had never been there.
        var reference = Crossfeed(preset: .defaultBS2B, sampleRate: 48_000)
        for n in 0..<4_800 {
            let x = 0.5 * sin(2 * .pi * 1_000 * Double(n) / 48_000)
            var (al, ar) = (x, x)
            var (bl, br) = (x, x)
            crossfeed.process(left: &al, right: &ar)
            reference.process(left: &bl, right: &br)
            #expect(al.isFinite && ar.isFinite)
            if n >= 2_400 {
                #expect(abs(al - bl) < 1e-9 && abs(ar - br) < 1e-9, "frame \(n)")
            }
        }
    }
}
