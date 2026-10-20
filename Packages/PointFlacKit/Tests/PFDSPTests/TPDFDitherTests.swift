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
