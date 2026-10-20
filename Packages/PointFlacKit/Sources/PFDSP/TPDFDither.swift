/// TPDF dither that reduces full-range 32-bit integer audio to 24 significant bits.
///
/// Each sample gets triangular noise (the sum of two independent uniform integers in [-128, 127], one
/// 256-wide LSB of the 24-bit target) added, is rounded to the nearest multiple of 256, and saturates at
/// `Int32.max & ~255` and `Int32.min`. Arithmetic is done in `Int64`, so nothing wraps.
///
/// The PRNG is xorshift64*, seeded deterministically, and samples are consumed strictly in order: running
/// the same seed over the same sample sequence reproduces the same output bit for bit. Each sample draws one
/// 64-bit PRNG output; its top byte and the next byte are the two uniform draws.
public struct TPDFDither: Sendable {
    private var state: UInt64

    /// - Parameter seed: Any value. Zero (a fixed point of xorshift) is remapped to a constant.
    public init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    private mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Dithers `samples` in place, in order. Output values are multiples of 256.
    public mutating func reduce32To24(_ samples: UnsafeMutableBufferPointer<Int32>) {
        let maxOut = Int64(Int32.max & ~255)
        let minOut = Int64(Int32.min)
        for i in samples.indices {
            let r = next()
            let a = Int64((r >> 56) & 0xFF) - 128
            let b = Int64((r >> 48) & 0xFF) - 128
            // Add 128, then floor to a multiple of 256: round to nearest.
            let rounded = (Int64(samples[i]) + a + b + 128) & ~255
            samples[i] = Int32(min(max(rounded, minOut), maxOut))
        }
    }
}
