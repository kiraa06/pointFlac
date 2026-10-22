import Foundation
import Testing

@testable import PFDSP

/// `SoundChain.preampStaging`, which the Sound tab's gain staging shows, is the gain a compiled chain applies.
@Suite("Preamp staging")
struct PreampStagingTests {
    private func settings(_ edit: (inout SoundSettings) -> Void) -> SoundSettings {
        var s = SoundSettings()
        s.pure = false
        edit(&s)
        return s
    }

    @Test("the parts sum to the chain's own preamp, and report which are off")
    func sumsAsTheChain() {
        let cases = [
            settings {
                $0.eq.enabled = true
                $0.eq.graphicGainsDb[0] = 6
                $0.preamp.trimDb = -2
            },
            settings {
                $0.correction = CorrectionSettings(
                    enabled: true, preampDb: -9.3, bands: [EQBand(type: .peak, frequency: 100, gainDb: 4, q: 1)])
                $0.preamp.autoHeadroom = false
            },
            settings {
                $0.tone.enabled = true
                $0.tone.bassDb = 12
                $0.preamp.trimDb = 3
            },
        ]
        for s in cases {
            let headroom = SoundResponse.autoHeadroomDb(s, sampleRate: 48_000)
            let staging = SoundChain.preampStaging(s, headroomDb: headroom)
            let chain = SoundChain(s, sampleRate: 48_000, channels: 2)
            #expect(abs(staging.totalDb - chain.preampDb) < 1e-12)
            #expect(!staging.capped)
            #expect((staging.correctionDb == nil) == !s.correction.enabled)
            #expect((staging.headroomDb == nil) == !s.preamp.autoHeadroom)
            #expect(staging.trimDb == s.preamp.trimDb)
        }
    }

    @Test("stacked boosts with headroom off are capped at the limiter's largest drive, as the chain caps them")
    func capped() {
        let s = settings {
            $0.eq.enabled = true
            $0.eq.mode = .parametric
            $0.eq.bands = (0..<20).map { _ in EQBand(type: .peak, frequency: 1000, gainDb: 24, q: 1) }
            $0.preamp.autoHeadroom = false
        }
        let headroom = SoundResponse.autoHeadroomDb(s, sampleRate: 48_000)
        let staging = SoundChain.preampStaging(s, headroomDb: headroom)
        #expect(staging.capped)
        #expect(staging.headroomDb == nil)
        #expect(abs(-headroom + staging.totalDb - TruePeakLimiter.maxDriveDb) < 1e-9)
        #expect(abs(staging.totalDb - SoundChain(s, sampleRate: 48_000, channels: 2).preampDb) < 1e-12)
    }
    @Test("the stages named are the blocks on, with the preamp exactly where its stage changes the level (R4-UI-c)")
    func stageNames() {
        let boost = settings {
            $0.eq.enabled = true
            $0.eq.graphicGainsDb[5] = 6
        }
        let headroom = SoundResponse.autoHeadroomDb(boost, sampleRate: 48_000)
        #expect(SoundChain.stageNames(boost, headroomDb: headroom) == ["Preamp", "EQ", "Limiter"])
        #expect(SoundChain.stageNames(boost, headroomDb: 0) == ["EQ", "Limiter"])
        var trimmed = boost
        trimmed.preamp.trimDb = -headroom
        #expect(SoundChain.stageNames(trimmed, headroomDb: headroom) == ["EQ", "Limiter"], "trim cancels headroom")
        var replayGain = settings { $0.replayGain.mode = .track }
        replayGain.preamp.trimDb = 1
        #expect(SoundChain.stageNames(replayGain, headroomDb: 0) == ["ReplayGain", "Preamp", "Limiter"])
        replayGain.pure = true
        #expect(SoundChain.stageNames(replayGain, headroomDb: 0).isEmpty)
        #expect(SoundChain.stageNames(settings { $0.preamp.trimDb = 0.04 }, headroomDb: 0) == ["Limiter"])
    }
}
