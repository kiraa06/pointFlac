import Testing

@testable import PFDSP

/// Deterministic full-range Int32 source (splitmix64) so the test input is reproducible.
private func randomInt32s(count: Int, seed: UInt64) -> [Int32] {
    var state = seed
    return (0..<count).map { _ in
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int32(truncatingIfNeeded: z)
    }
}

private func dither(_ input: [Int32], seed: UInt64 = 1) -> [Int32] {
    var samples = input
    var d = TPDFDither(seed: seed)
    samples.withUnsafeMutableBufferPointer { d.reduce32To24($0) }
    return samples
}

@Test func ditherOutputsMultiplesOf256WithinTwoLSB() {
    let input = randomInt32s(count: 100_000, seed: 42)
    let output = dither(input)
    for (i, o) in zip(input, output) {
        #expect(o % 256 == 0)
        #expect(abs(Int64(o) - Int64(i)) <= 512)
    }
}

@Test func ditherIsUnbiased() {
    let output = dither([Int32](repeating: 1000, count: 100_000))
    let mean = output.reduce(0.0) { $0 + Double($1) } / Double(output.count)
    #expect(abs(mean - 1000) < 4)
}

@Test func ditherSaturatesWithoutWrap() {
    let input = [Int32](repeating: .max, count: 1000) + [Int32](repeating: .min, count: 1000)
    let output = dither(input)
    #expect(output[..<1000].allSatisfy { $0 <= Int32.max & ~255 && $0 > Int32.max - 1024 })
    #expect(output[1000...].allSatisfy { $0 >= Int32.min && $0 < Int32.min + 1024 })
    #expect(output.contains(Int32.max & ~255))
    #expect(output.contains(Int32.min))
}

@Test func ditheredValuesConvertExactlyToFloat32() {
    let output = dither(randomInt32s(count: 100_000, seed: 7))
    for o in output {
        #expect(Double(Float(o) / 2_147_483_648.0 * 2_147_483_648.0) == Double(o))
    }
}

@Test func ditherIsDeterministicForSeed() {
    let input = randomInt32s(count: 1000, seed: 3)
    #expect(dither(input, seed: 9) == dither(input, seed: 9))
    #expect(dither(input, seed: 9) != dither(input, seed: 10))
}

// MARK: TPDF shape (ledger T8)

/// The dither noise itself, over 2^20 draws from a fixed seed. Each draw is the sum of two independent uniform integers
/// in [−128, 127]: a triangle two 24-bit LSBs (2 × 256) wide. Its variance is 2·(256² − 1)/12, which is 2·256²/12 to
/// within 0.002 %; its mean is −1, which is 0 against a 256-step LSB; and its histogram rises linearly to the centre,
/// so in eight 64-wide bins the two centre bins hold 7× what the two edge bins do. A uniform (RPDF) dither of either
/// width fails all of it.
@Test func ditherNoiseIsTriangular() {
    var d = TPDFDither(seed: 0x5EED)
    let n = 1 << 20
    var sum = 0.0
    var sumOfSquares = 0.0
    var bins = [Int](repeating: 0, count: 8)
    var outside = 0
    for _ in 0..<n {
        let v = d.nextNoise()
        sum += Double(v)
        sumOfSquares += Double(v) * Double(v)
        let bin = Int((v + 256) / 64)
        if (0..<8).contains(bin) { bins[bin] += 1 } else { outside += 1 }
    }
    let mean = sum / Double(n)
    let variance = sumOfSquares / Double(n) - mean * mean
    let expected = 2.0 * 256 * 256 / 12
    #expect(abs(variance / expected - 1) < 0.02, "variance \(variance), expected ≈ \(expected)")
    #expect(abs(mean) < 2, "mean \(mean)")
    #expect(outside == 0, "draws outside [−256, 256)")
    let ratio = Double(bins[3] + bins[4]) / Double(bins[0] + bins[7])
    #expect(abs(ratio / 7 - 1) < 0.05, "centre/edge \(ratio); bins \(bins)")
    // Each bin within 3 % of the triangle's exact share (the counts of a + b over all 65536 pairs).
    let exact = [2080, 6176, 10272, 14368, 14304, 10208, 6112, 2016].map { Double($0) / 65536 }
    for (i, share) in exact.enumerated() {
        #expect(abs(Double(bins[i]) / Double(n) / share - 1) < 0.03, "bin \(i): \(bins)")
    }
}

/// The same shape from outside, on a zero input. The output error is the dither plus the rounding to a multiple of 256,
/// so its variance is 256²/12 + 2·256²/12 = 256²/4, TPDF's input-independent total, rather than the noise's 2·256²/12
/// alone (asserted above). The error takes only the values −256, 0 and 256, the centre three times as often as both
/// edges together, and its mean is ≈ 0 (exactly −0.5). A dither one LSB wide leaves a zero input untouched (variance
/// 0); a uniform one two LSBs wide gives 256²/2 with a centre/edge ratio of 1.
@Test func ditherErrorOnZeroInputHasTheTPDFVariance() {
    let output = dither([Int32](repeating: 0, count: 1 << 20), seed: 0xD1CE)
    var counts: [Int32: Int] = [:]
    for v in output { counts[v, default: 0] += 1 }
    #expect(Set(counts.keys).isSubset(of: [-256, 0, 256]), "values \(counts.keys.sorted())")
    let n = Double(output.count)
    let mean = output.reduce(0.0) { $0 + Double($1) } / n
    let variance = output.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
    #expect(abs(variance / (256.0 * 256 / 4) - 1) < 0.02, "variance \(variance)")
    #expect(abs(mean) < 2, "mean \(mean)")
    let ratio = Double(counts[0, default: 0]) / Double(counts[-256, default: 0] + counts[256, default: 0])
    #expect(abs(ratio / 3 - 1) < 0.03, "centre/edges \(ratio); counts \(counts)")
}

/// A fixed-seed golden vector, computed by an independent reimplementation (xorshift64*, the top two bytes of each draw
/// as the two uniforms), so the pipeline captures that compare against `TPDFDither` itself rest on fixed numbers. The
/// inputs sit between multiples of 256, where the noise decides the rounding: with either uniform alone, with no
/// dither, or with the next seed, between 2 and 6 of the 16 outputs differ. The last values exercise saturation.
@Test func ditherGoldenVector() {
    let input: [Int32] = [
        64, 192, -64, -192, 100, 156, -100, -156, 0x1234_5640, 0x1234_56C0, -0x1234_5640, 1000, -1000, 0x7FFF_FF80,
        -0x7FFF_FF40, 32,
    ]
    let expected: [Int32] = [
        0, 256, 0, -256, 256, 256, -256, 0, 305_420_032, 305_420_032, -305_420_032, 1024, -1024, 2_147_483_392,
        -2_147_483_392, 256,
    ]
    #expect(dither(input, seed: 0x0123_4567_89AB_CDEF) == expected)
    #expect(dither(input, seed: 0x0123_4567_89AB_CDF0) != expected)
}
