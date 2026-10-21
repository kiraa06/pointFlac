import Foundation
import Testing

@testable import PFLoudness

/// EBU Tech 3341 reference signals, generated here rather than bundled.
@Suite("LoudnessMeter")
struct LoudnessMeterTests {
    /// Interleaved stereo sine, the same signal on both channels.
    static func stereoSine(
        hz: Double, dbfs: Double, seconds: Double, rate: Int, phase: Double = 0
    ) -> [Float] {
        let frames = Int(seconds * Double(rate))
        let amp = pow(10, dbfs / 20)
        var out = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Float(amp * sin(2 * .pi * hz * Double(i) / Double(rate) + phase))
            out[2 * i] = v
            out[2 * i + 1] = v
        }
        return out
    }

    static func measure(_ samples: [Float], channels: Int = 2, rate: Int = 48_000) throws -> LoudnessMeter {
        let meter = try LoudnessMeter(channels: channels, sampleRate: rate)
        samples.withUnsafeBufferPointer { meter.add($0, frames: samples.count / channels) }
        return meter
    }

    @Test("a 1 kHz stereo sine at -23 dBFS reads -23 LUFS")
    func minus23() throws {
        // Both channels carry the sine, so the BS.1770 channel sum doubles the energy and cancels the sine's
        // -3.01 dB RMS: the reading equals the peak level in dBFS (K-weighting is +0.69 dB at 1 kHz, offset by -0.691).
        let meter = try Self.measure(Self.stereoSine(hz: 1000, dbfs: -23, seconds: 20, rate: 48_000))
        #expect(abs(meter.integratedLufs - -23.0) <= 0.1)
    }

    @Test("a stereo sine at -33 LUFS reads -33 LUFS")
    func minus33() throws {
        let meter = try Self.measure(Self.stereoSine(hz: 1000, dbfs: -33, seconds: 20, rate: 48_000))
        #expect(abs(meter.integratedLufs - -33.0) <= 0.1)
    }

    @Test("a 0 dBFS sine at fs/4 with 45 degree phase has a 0 dBTP true peak")
    func truePeak() throws {
        let meter = try Self.measure(
            Self.stereoSine(hz: 12_000, dbfs: 0, seconds: 2, rate: 48_000, phase: .pi / 4))
        #expect(abs(meter.truePeakDbTP - 0.0) <= 0.2)
        // Every sample is +-0.7071, so a plain sample peak would read -3 dBFS; the oversampled peak must find 0.
    }

    @Test("two meters at -20 and -26 LUFS give an album value of -22 LUFS")
    func album() throws {
        let a = try Self.measure(Self.stereoSine(hz: 1000, dbfs: -20, seconds: 20, rate: 48_000))
        let b = try Self.measure(Self.stereoSine(hz: 1000, dbfs: -26, seconds: 20, rate: 48_000))
        #expect(abs(a.integratedLufs - -20.0) <= 0.1)
        #expect(abs(b.integratedLufs - -26.0) <= 0.1)
        #expect(abs(LoudnessMeter.albumLufs([a, b]) - -22.0) <= 0.2)
    }

    @Test("silence reads negative infinity")
    func silence() throws {
        let meter = try Self.measure([Float](repeating: 0, count: 48_000 * 2 * 2))
        #expect(meter.integratedLufs == -.infinity)
        #expect(meter.truePeakDbTP == -.infinity)
    }

    @Test("invalid channel counts and rates throw")
    func invalid() {
        #expect(throws: LoudnessMeter.Failure.self) { try LoudnessMeter(channels: 0, sampleRate: 48_000) }
        #expect(throws: LoudnessMeter.Failure.self) { try LoudnessMeter(channels: 2, sampleRate: 0) }
        #expect(throws: LoudnessMeter.Failure.self) { try LoudnessMeter(channels: 2, sampleRate: -44_100) }
        // 16 and 17 Hz overrun libebur128's buffers; below 8 kHz is no music.
        for rate in [16, 17, 100, 7_999, 2_822_401] {
            #expect(throws: LoudnessMeter.Failure.self) { try LoudnessMeter(channels: 2, sampleRate: rate) }
        }
        #expect(throws: LoudnessMeter.Failure.self) { try LoudnessMeter(channels: 65, sampleRate: 48_000) }
        #expect((try? LoudnessMeter(channels: 2, sampleRate: 8_000)) != nil)
    }

    @Test("5.1 and 7.1 ignore the LFE channel")
    func lfeIgnored() throws {
        for channels in [6, 8] {
            let frames = 48_000 * 10
            var withLfe = [Float](repeating: 0, count: frames * channels)
            var without = withLfe
            let amp = Float(pow(10, -23.0 / 20))
            for i in 0..<frames {
                let v = amp * Float(sin(2 * .pi * 1000 * Double(i) / 48_000))
                withLfe[i * channels] = v
                without[i * channels] = v
                withLfe[i * channels + 3] = 0.9 * v  // LFE
            }
            let a = try Self.measure(withLfe, channels: channels)
            let b = try Self.measure(without, channels: channels)
            #expect(abs(a.integratedLufs - b.integratedLufs) < 0.001)
        }
    }

    @Test("surround channels weigh 1.41 (about +1.5 dB) in 5.1 and 7.1")
    func surroundWeight() throws {
        for (channels, surround) in [(6, 4), (8, 4), (8, 6)] {
            let frames = 48_000 * 10
            var front = [Float](repeating: 0, count: frames * channels)
            var back = front
            for i in 0..<frames {
                let v = 0.05 * Float(sin(2 * .pi * 1000 * Double(i) / 48_000))
                front[i * channels] = v
                back[i * channels + surround] = v
            }
            let f = try Self.measure(front, channels: channels).integratedLufs
            let s = try Self.measure(back, channels: channels).integratedLufs
            #expect(abs((s - f) - 10 * log10(1.41)) < 0.01)
        }
    }

    @Test("a finished meter keeps its answers, ignores more audio and still pools")
    func finishFreesMemory() throws {
        let samples = Self.stereoSine(hz: 1000, dbfs: -20, seconds: 20, rate: 96_000)
        let meter = try Self.measure(samples, rate: 96_000)
        let lufs = meter.integratedLufs
        let peak = meter.truePeakDbTP
        meter.finish()
        #expect(meter.integratedLufs == lufs && meter.truePeakDbTP == peak)
        // (The memory it gives back is measured outside the suite: parallel tests make heap counts meaningless here.)
        // A finished meter still pools into an album value, and ignores further audio.
        samples.withUnsafeBufferPointer { meter.add($0, frames: samples.count / 2) }
        #expect(meter.integratedLufs == lufs)
        let other = try Self.measure(Self.stereoSine(hz: 1000, dbfs: -26, seconds: 20, rate: 96_000), rate: 96_000)
        other.finish()
        #expect(abs(LoudnessMeter.albumLufs([meter, other]) - -22.0) <= 0.2)
    }
}
