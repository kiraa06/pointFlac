import CEBUR128
import Foundation

/// An EBU R128 / ITU-R BS.1770 loudness meter over libebur128: integrated loudness (LUFS) and true peak (dBTP).
///
/// Not `Sendable`: it owns a mutable C state with no locking. Create it, feed it and read it from one task (the
/// library scan runs one meter per track on a background task); never from the render thread, since `add` allocates.
public final class LoudnessMeter {
    public enum Failure: Error, Equatable {
        /// The channel count or sample rate is out of range (libebur128 takes 1... channels and rates >= 16 Hz).
        case invalidFormat
        /// libebur128 could not allocate its state.
        case initFailed
    }

    private var state: UnsafeMutablePointer<ebur128_state>?

    public init(channels: Int, sampleRate: Int) throws {
        guard channels >= 1, channels <= Int(UInt32.max), sampleRate >= 16, sampleRate <= Int(UInt32.max) else {
            throw Failure.invalidFormat
        }
        let mode = Int32(EBUR128_MODE_I.rawValue | EBUR128_MODE_TRUE_PEAK.rawValue)
        guard let made = ebur128_init(UInt32(channels), UInt(sampleRate), mode) else { throw Failure.initFailed }
        state = made
        Self.applyChannelMap(made, channels: channels)
    }

    deinit {
        // ebur128_destroy dereferences its argument, and deinit also runs when `init` threw before `state` was set.
        if state != nil { ebur128_destroy(&state) }
    }

    /// libebur128's default map already fits FLAC's mono, stereo and 5.1 order (L R C LFE Ls Rs), but 7.1 would leave
    /// the fourth pair unused. FLAC orders 7.1 as L R C LFE BL BR SL SR; BS.1770 weights the surround channels at
    /// 1.41 and ignores the LFE, so BL/BR map to M+-110 and SL/SR to M+-090 (all weighted), and index 3 is unused.
    private static func applyChannelMap(_ state: UnsafeMutablePointer<ebur128_state>, channels: Int) {
        let map: [(Int, channel)]
        switch channels {
        case 6:
            map = [
                (0, EBUR128_LEFT), (1, EBUR128_RIGHT), (2, EBUR128_CENTER), (3, EBUR128_UNUSED),
                (4, EBUR128_LEFT_SURROUND), (5, EBUR128_RIGHT_SURROUND),
            ]
        case 8:
            map = [
                (0, EBUR128_LEFT), (1, EBUR128_RIGHT), (2, EBUR128_CENTER), (3, EBUR128_UNUSED),
                (4, EBUR128_Mp110), (5, EBUR128_Mm110), (6, EBUR128_Mp090), (7, EBUR128_Mm090),
            ]
        default:
            return  // Mono and stereo: the defaults.
        }
        for (index, kind) in map {
            _ = ebur128_set_channel(state, UInt32(index), Int32(kind.rawValue))
        }
    }

    /// Feeds `frames` interleaved frames. `interleaved` must hold at least `frames * channels` samples.
    public func add(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) {
        guard let state, frames > 0, let base = interleaved.baseAddress else { return }
        precondition(interleaved.count >= frames * Int(state.pointee.channels), "short buffer")
        _ = ebur128_add_frames_float(state, base, frames)
    }

    /// Gated integrated loudness in LUFS. Silence (nothing above the -70 LUFS absolute gate) is `-.infinity`, which is
    /// libebur128's `-HUGE_VAL`.
    public var integratedLufs: Double {
        guard let state else { return -.infinity }
        var out = -Double.infinity
        guard ebur128_loudness_global(state, &out) == 0 else { return -.infinity }
        return out
    }

    /// The largest true peak over all channels, in dBTP (0 dBTP = full scale); `-.infinity` for silence.
    public var truePeakDbTP: Double {
        guard let state else { return -.infinity }
        var peak = 0.0
        for channel in 0..<state.pointee.channels {
            var p = 0.0
            if ebur128_true_peak(state, channel, &p) == 0 { peak = max(peak, p) }
        }
        return 20 * log10(peak)
    }

    /// The integrated loudness of several tracks taken together (an album), over the pooled gating blocks.
    public static func albumLufs(_ meters: [LoudnessMeter]) -> Double {
        var states: [UnsafeMutablePointer<ebur128_state>?] = meters.compactMap { $0.state }
        guard !states.isEmpty else { return -.infinity }
        var out = -Double.infinity
        let status = withExtendedLifetime(meters) { ebur128_loudness_global_multiple(&states, states.count, &out) }
        return status == 0 ? out : -.infinity
    }
}
