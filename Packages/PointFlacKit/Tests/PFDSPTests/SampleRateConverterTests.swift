import Foundation
import Testing

@testable import PFDSP

/// Mono sine, `seconds` long, at the given amplitude (linear).
private func sine(freq: Double, amplitude: Double, rate: Int, seconds: Double) -> [Float] {
    (0..<Int(Double(rate) * seconds)).map { n in
        Float(amplitude * sin(2 * Double.pi * freq * Double(n) / Double(rate)))
    }
}

private func convert(_ input: [Float], from: Int, to: Int, chunk: Int = 4096) throws -> [Float] {
    let c = try SampleRateConverter(inputRate: from, outputRate: to, channels: 1)
    var out: [Float] = []
    var pos = 0
    while pos < input.count {
        let n = min(chunk, input.count - pos)
        input[pos..<pos + n].withUnsafeBufferPointer { _ = c.process($0, frames: n, into: &out) }
        pos += n
    }
    _ = c.flush(into: &out)
    return out
}

private func rmsDBFS(_ x: ArraySlice<Float>) -> Double {
    let ms = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
    return 10 * log10(ms)
}

private let edge = 2048

@Test func resamplerPreservesPassbandSine() throws {
    let amp = pow(10.0, -1.0 / 20.0)
    let out = try convert(sine(freq: 1000, amplitude: amp, rate: 96_000, seconds: 1), from: 96_000, to: 48_000)
    let steady = out[edge..<(out.count - edge)]
    let expected = 20 * log10(amp / 2.0.squareRoot())
    let measured = rmsDBFS(steady)
    #expect(abs(measured - expected) <= 0.05)
}

@Test func resamplerRejectsAboveNewNyquist() throws {
    let out = try convert(sine(freq: 30_000, amplitude: 1.0, rate: 96_000, seconds: 1), from: 96_000, to: 48_000)
    let measured = rmsDBFS(out[edge..<(out.count - edge)])
    #expect(measured < -90)
}

@Test func resamplerFrameCountMatchesRatio() throws {
    let a = try convert([Float](repeating: 0.1, count: 96_000), from: 96_000, to: 48_000)
    #expect(abs(a.count - 48_000) <= 64)
    let b = try convert([Float](repeating: 0.1, count: 44_100), from: 44_100, to: 48_000)
    #expect(abs(b.count - 48_000) <= 64)
}
