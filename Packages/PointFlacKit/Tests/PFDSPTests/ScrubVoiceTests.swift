import Foundation
import Testing

@testable import PFDSP

/// The scrub voice's parts: the band-limited variable-rate reader, the platter follower and the voice itself.
@Suite("Scrub audio")
struct ScrubVoiceTests {
    static let rate = 48_000.0

    /// A ring of `frames` (a power of two) mono or stereo frames, filled by `sample(frame, channel)`.
    static func ring(frames: Int, channels: Int, _ sample: (Int, Int) -> Float) -> [Float] {
        var ring = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels { ring[frame * channels + channel] = sample(frame, channel) }
        }
        return ring
    }

    static func sine(_ hz: Double, _ frame: Double) -> Double { sin(2 * .pi * hz * frame / rate) }

    /// RMS of `x` against `reference`, as a fraction of the reference's RMS.
    static func relativeError(_ x: [Double], _ reference: [Double]) -> Double {
        let err = zip(x, reference).map { ($0 - $1) * ($0 - $1) }.reduce(0, +)
        let ref = reference.map { $0 * $0 }.reduce(0, +)
        return (err / max(ref, 1e-30)).squareRoot()
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        (x.map { Double($0) * Double($0) }.reduce(0, +) / Double(max(x.count, 1))).squareRoot()
    }

    // MARK: Kernel

    @Test("At full bandwidth the kernel reads a sine exactly at whole and fractional positions")
    func kernelReadsBetweenSamples() {
        let kernel = ScrubKernel()
        let frames = 8192
        let ring = Self.ring(frames: frames, channels: 1) { f, _ in Float(Self.sine(1_000, Double(f))) }
        var got: [Double] = []
        var want: [Double] = []
        ring.withUnsafeBufferPointer { buffer in
            var out: Float = 0
            for step in 0..<400 {
                let position = 2_000 + Double(step) * 0.37
                kernel.read(
                    ring: buffer.baseAddress!, mask: frames - 1, channels: 1, position: position, cutoff: 1,
                    into: &out)
                got.append(Double(out))
                want.append(Self.sine(1_000, position))
            }
        }
        #expect(Self.relativeError(got, want) < 1e-3)
    }

    @Test("Read 4× faster, a tone that would land above the output's Nyquist is filtered out; one below passes")
    func kernelAntiAliases() {
        let kernel = ScrubKernel()
        let frames = 1 << 16
        func level(_ hz: Double) -> Double {
            let ring = Self.ring(frames: frames, channels: 1) { f, _ in Float(Self.sine(hz, Double(f))) }
            var out = [Float](repeating: 0, count: 4_000)
            ring.withUnsafeBufferPointer { buffer in
                for i in out.indices {
                    kernel.read(
                        ring: buffer.baseAddress!, mask: frames - 1, channels: 1, position: 1_000 + Double(i) * 4,
                        cutoff: ScrubKernel.cutoff(forAdvance: 4), into: &out[i])
                }
            }
            return Self.rms(out[200...]) / (0.5).squareRoot()
        }
        #expect(level(2_000) > 0.89)  // 8 kHz out: within 1 dB
        #expect(level(10_000) < 0.01)  // 40 kHz out, beyond 24 kHz: at least 40 dB down
    }

    @Test("Stereo channels are read independently")
    func kernelKeepsChannelsApart() {
        let kernel = ScrubKernel()
        let frames = 4096
        let ring = Self.ring(frames: frames, channels: 2) { _, c in c == 0 ? 0.5 : -0.25 }
        var out: [Float] = [0, 0]
        ring.withUnsafeBufferPointer { buffer in
            kernel.read(
                ring: buffer.baseAddress!, mask: frames - 1, channels: 2, position: 1_000.5, cutoff: 1, into: &out)
        }
        #expect(abs(out[0] - 0.5) < 1e-5 && abs(out[1] + 0.25) < 1e-5)
    }

    // MARK: Follower

    @Test("A hand that jumps and stops is followed without overshoot and settles within 60 ms")
    func followerSettlesOnAStep() {
        var follower = PlatterFollower(position: 0, velocity: 0)
        var peak = 0.0
        let settle = Int(0.06 * Self.rate)
        for _ in 0..<settle {
            follower.follow(1_000, omega: PlatterFollower.handOmega(outputRate: Self.rate))
            peak = max(peak, follower.position)
        }
        #expect(abs(follower.position - 1_000) < 0.5)
        #expect(peak < 1_000.01)
    }

    @Test("A hand turning steadily sets the read speed to the hand's speed: the pitch follows the hand")
    func followerMatchesHandSpeed() {
        var follower = PlatterFollower(position: 0, velocity: 0)
        let speed = 0.6  // source frames per output frame
        for frame in 0..<Int(0.2 * Self.rate) {
            follower.follow(Double(frame) * speed, omega: PlatterFollower.handOmega(outputRate: Self.rate))
        }
        #expect(abs(follower.velocity - speed) < 1e-3)
    }

    @Test("The motor spins the platter up to speed within its response time")
    func motorSpinsUp() {
        var follower = PlatterFollower(position: 0, velocity: 0)
        let frames = Int(PlatterFollower.spinUpSeconds * Self.rate)
        for _ in 0..<frames {
            follower.drive(toward: 1, framesToSpeed: Double(frames))
        }
        #expect(follower.velocity > 0.98 && follower.velocity <= 1)
    }

    // MARK: Voice

    /// Runs `voice` over `ring` for `frames` output frames, calling `hand` before each block of 128.
    static func run(
        _ voice: inout ScrubVoice, ring: [Float], ringFrames: Int, frames: Int, channels: Int = 1,
        hand: (Int, inout ScrubVoice) -> Void = { _, _ in }
    ) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        ring.withUnsafeBufferPointer { buffer in
            out.withUnsafeMutableBufferPointer { output in
                var done = 0
                while done < frames {
                    hand(done, &voice)
                    let n = min(128, frames - done)
                    voice.render(
                        ring: buffer.baseAddress!, mask: ringFrames - 1, valid: 0..<Int64(ringFrames), frames: n,
                        into: output.baseAddress! + done * channels)
                    done += n
                }
            }
        }
        return out
    }

    @Test("Holding the record still is silent, not a held level")
    func stillHandIsSilent() {
        let frames = 1 << 16
        let ring = Self.ring(frames: frames, channels: 1) { _, _ in 0.8 }  // a DC level a held sample would show
        var voice = ScrubVoice(channels: 1, sourceRate: Self.rate, outputRate: Self.rate, at: 20_000)
        voice.hand(target: 20_000, speed: 0)
        let out = Self.run(&voice, ring: ring, ringFrames: frames, frames: Int(0.5 * Self.rate))
        #expect(Self.rms(out[Int(0.3 * Self.rate)...]) < 1e-3)
    }

    @Test("Turning at normal speed plays the music as recorded")
    func normalSpeedIsTheRecording() {
        let frames = 1 << 17
        let ring = Self.ring(frames: frames, channels: 1) { f, _ in Float(0.5 * Self.sine(997, Double(f))) }
        let start = 10_000.0
        var voice = ScrubVoice(channels: 1, sourceRate: Self.rate, outputRate: Self.rate, at: start, speed: 1)
        let count = Int(0.5 * Self.rate)
        let out = Self.run(&voice, ring: ring, ringFrames: frames, frames: count) { done, voice in
            voice.hand(target: start + Double(done), speed: 1)
        }
        let tail = Array(out[(count / 2)...]).map(Double.init)
        let offset = start + Double(count / 2)
        let want = (0..<tail.count).map { 0.5 * Self.sine(997, offset + Double($0)) }
        #expect(Self.relativeError(tail, want) < 0.02)
    }

    @Test("Turning backwards plays the music backwards")
    func backwardsIsReversed() {
        let frames = 1 << 17
        let ring = Self.ring(frames: frames, channels: 1) { f, _ in Float(0.5 * Self.sine(613, Double(f))) }
        let start = 90_000.0
        var voice = ScrubVoice(channels: 1, sourceRate: Self.rate, outputRate: Self.rate, at: start, speed: -1)
        let count = Int(0.5 * Self.rate)
        let out = Self.run(&voice, ring: ring, ringFrames: frames, frames: count) { done, voice in
            voice.hand(target: start - Double(done), speed: -1)
        }
        let tail = Array(out[(count / 2)...]).map(Double.init)
        let offset = start - Double(count / 2)
        let want = (0..<tail.count).map { 0.5 * Self.sine(613, offset - Double($0)) }
        #expect(Self.relativeError(tail, want) < 0.02)
    }

    @Test("Between hand updates the voice keeps the hand's speed, so 60 Hz touches give a steady pitch")
    func handUpdatesDoNotStepThePitch() {
        let frames = 1 << 17
        let ring = Self.ring(frames: frames, channels: 1) { f, _ in Float(0.5 * Self.sine(500, Double(f))) }
        var voice = ScrubVoice(channels: 1, sourceRate: Self.rate, outputRate: Self.rate, at: 10_000, speed: 0.75)
        let touch = Int(Self.rate / 60)
        var speeds: [Double] = []
        _ = Self.run(&voice, ring: ring, ringFrames: frames, frames: Int(0.6 * Self.rate)) { done, voice in
            if done % touch < 128 { voice.hand(target: 10_000 + Double(done) * 0.75, speed: 0.75) }
            if done > Int(0.3 * Self.rate) { speeds.append(voice.speed) }
        }
        let spread = (speeds.max() ?? 0) - (speeds.min() ?? 0)
        #expect(spread < 0.0075)  // under 1 % of the speed: no audible flutter at the touch rate
    }

    @Test("Outside the decoded window the voice is silent instead of reading stale audio")
    func outsideTheWindowIsSilent() {
        let frames = 1 << 14
        let ring = Self.ring(frames: frames, channels: 1) { _, _ in 0.9 }
        var voice = ScrubVoice(channels: 1, sourceRate: Self.rate, outputRate: Self.rate, at: 50_000, speed: 1)
        var out = [Float](repeating: 1, count: 256)
        ring.withUnsafeBufferPointer { buffer in
            out.withUnsafeMutableBufferPointer { output in
                voice.hand(target: 50_000, speed: 1)
                voice.render(
                    ring: buffer.baseAddress!, mask: frames - 1, valid: 0..<10_000, frames: 256,
                    into: output.baseAddress!)
            }
        }
        #expect(out.allSatisfy { $0 == 0 })
    }
}
