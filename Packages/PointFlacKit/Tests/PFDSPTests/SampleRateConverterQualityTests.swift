import Foundation
import Testing

@testable import PFDSP

/// Quality bounds for `SampleRateConverter` (AVAudioConverter, Mastering, max quality) on the conversions
/// playback uses: 192, 96, 88.2 and 44.1 kHz to 48 kHz.
///
/// Every tone is run through a fresh converter exactly as `DecodeSession.play` drives it: 4096-frame blocks,
/// then `flush`. Nothing is read off sample peaks. For each output tone:
/// - Amplitude and phase come from a Hann-windowed least-squares fit of `a*cos + b*sin + c` at the known
///   frequency, over the output with the first and last `trimSeconds` discarded (start-up and flush transients).
///   The constant term absorbs any DC, and the window plus >= 10 cycles keeps spectral leakage far below the
///   bounds. Passband response is `20*log10(amplitude / inputAmplitude)`.
/// - Delay (in output samples) is the per-tone phase delay `-phase / omega`. For a linear-phase filter this
///   equals the group delay (the phase slope across frequency) and is constant across the band. The phase
///   wraps at high frequency, so it is unwrapped going up in frequency, taking the delay candidate nearest
///   the previous tone's.
/// - Stopband tones sit above 24.5 kHz in the source, where nothing may reach the 48 kHz output. The output
///   RMS (everything that landed there, aliases included, at whatever frequency) is measured over the same
///   trimmed, windowed span and compared with the input tone's RMS. Only conversions whose source rate has
///   content above 24.5 kHz (192, 96, 88.2) have a stopband to test; 44.1 kHz does not (Nyquist 22.05 kHz).
private struct Measurement {
    var passband: [(freq: Double, gainDB: Double)] = []
    var delays: [(freq: Double, samples: Double)] = []
    var stopband: [(freq: Double, levelDB: Double)] = []
}

private let outRate = 48_000
private let blockFrames = 4096
private let amplitude = 0.5
private let trimSeconds = 0.15

/// 40 log-spaced tones over 20 Hz to 20 kHz (4 per octave) plus the top of the band, densely.
private let passbandFreqs: [Double] = {
    let n = 40
    let swept = (0...n).map { 20.0 * pow(1000.0, Double($0) / Double(n)) }
    return swept + [18_000, 19_000, 19_500]
}()

private let stopbandFreqs: [Double] = [
    24_500, 25_000, 26_000, 28_000, 30_000, 33_000, 36_000, 40_000, 44_000, 47_900, 48_100, 52_000, 60_000, 72_000,
    84_000, 95_000,
]

private func resample(_ input: [Float], from: Int) throws -> [Float] {
    let c = try SampleRateConverter(inputRate: from, outputRate: outRate, channels: 1)
    var out: [Float] = []
    var pos = 0
    while pos < input.count {
        let n = min(blockFrames, input.count - pos)
        input[pos..<pos + n].withUnsafeBufferPointer { _ = c.process($0, frames: n, into: &out) }
        pos += n
    }
    _ = c.flush(into: &out)
    return out
}

private func tone(_ freq: Double, rate: Int, seconds: Double) -> [Float] {
    (0..<Int(Double(rate) * seconds)).map { Float(amplitude * sin(2 * Double.pi * freq * Double($0) / Double(rate))) }
}

private func hann(_ i: Int, _ count: Int) -> Double {
    0.5 - 0.5 * cos(2 * Double.pi * (Double(i) + 0.5) / Double(count))
}

/// Windowed least-squares fit of `y[n] ~ a cos(wn) + b sin(wn) + c` for n in `range`. Returns amplitude and
/// the phase `phi` in `y = A sin(wn + phi)`.
private func fit(_ y: [Float], range: Range<Int>, freq: Double) -> (amp: Double, phase: Double) {
    let w = 2 * Double.pi * freq / Double(outRate)
    var m = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
    var r = [Double](repeating: 0, count: 3)
    let count = range.count
    for (i, n) in range.enumerated() {
        let win = hann(i, count)
        let basis = [cos(w * Double(n)), sin(w * Double(n)), 1]
        for p in 0..<3 {
            r[p] += win * basis[p] * Double(y[n])
            for q in 0..<3 { m[p][q] += win * basis[p] * basis[q] }
        }
    }
    // Gaussian elimination with partial pivoting on the 3x3 normal equations.
    for col in 0..<3 {
        let piv = (col..<3).max { abs(m[$0][col]) < abs(m[$1][col]) }!
        m.swapAt(col, piv)
        r.swapAt(col, piv)
        for row in (col + 1)..<3 {
            let f = m[row][col] / m[col][col]
            for k in col..<3 { m[row][k] -= f * m[col][k] }
            r[row] -= f * r[col]
        }
    }
    var x = [Double](repeating: 0, count: 3)
    for row in stride(from: 2, through: 0, by: -1) {
        var s = r[row]
        for k in (row + 1)..<3 { s -= m[row][k] * x[k] }
        x[row] = s / m[row][row]
    }
    return ((x[0] * x[0] + x[1] * x[1]).squareRoot(), atan2(x[0], x[1]))
}

private func trimmedRange(_ count: Int) -> Range<Int> {
    let trim = Int(trimSeconds * Double(outRate))
    return trim..<(count - trim)
}

private func measure(from rate: Int) throws -> Measurement {
    var result = Measurement()
    var previousDelay: Double?
    for f in passbandFreqs.sorted() {
        // At least 10 cycles in the fitted span, and never less than 0.5 s of signal in total.
        let seconds = max(0.5, 10 / f + 2 * trimSeconds)
        let out = try resample(tone(f, rate: rate, seconds: seconds), from: rate)
        let (amp, phase) = fit(out, range: trimmedRange(out.count), freq: f)
        result.passband.append((f, 20 * log10(amp / amplitude)))

        let w = 2 * Double.pi * f / Double(outRate)
        var delay = -phase / w
        let period = 2 * Double.pi / w
        if let previousDelay {
            delay += period * ((previousDelay - delay) / period).rounded()
        } else {
            // 20 Hz: the period (2400 samples) dwarfs any plausible latency, so the principal value is the delay.
            delay -= period * (delay / period).rounded()
        }
        previousDelay = delay
        result.delays.append((f, delay))
    }
    if rate / 2 > 24_500 {
        for f in stopbandFreqs where f < Double(rate) / 2 {
            let out = try resample(tone(f, rate: rate, seconds: 1), from: rate)
            let range = trimmedRange(out.count)
            var num = 0.0
            var den = 0.0
            for (i, n) in range.enumerated() {
                let win = hann(i, range.count)
                num += win * Double(out[n]) * Double(out[n])
                den += win
            }
            let outRMS = (num / den).squareRoot()
            let inRMS = amplitude / 2.0.squareRoot()
            result.stopband.append((f, 20 * log10(max(outRMS, 1e-12) / inRMS)))
        }
    }
    return result
}

/// Runs each conversion's sweep once and shares it between the three bound tests.
private actor Sweeps {
    static let shared = Sweeps()
    private var cache: [Int: Measurement] = [:]
    func get(_ rate: Int) throws -> Measurement {
        if let m = cache[rate] { return m }
        let m = try measure(from: rate)
        cache[rate] = m
        return m
    }
}

private let rates = [192_000, 96_000, 88_200, 44_100]

private func fmt(_ x: Double) -> String { String(format: "%.6f", x) }

@Test(arguments: rates)
func passbandRippleWithinTenthOfADecibel(rate: Int) async throws {
    let m = try await Sweeps.shared.get(rate)
    let worst = m.passband.max { abs($0.gainDB) < abs($1.gainDB) }!
    report("PASSBAND \(rate)->48k worst \(worst.gainDB) dB @ \(Int(worst.freq)) Hz")
    for p in m.passband { report("  \(rate) \(Int(p.freq)) Hz \(fmt(p.gainDB)) dB") }
    #expect(abs(worst.gainDB) < 0.1, "\(rate): \(worst.gainDB) dB at \(worst.freq) Hz")
}

@Test(arguments: rates)
func stopbandBelowMinus100dB(rate: Int) async throws {
    let m = try await Sweeps.shared.get(rate)
    guard !m.stopband.isEmpty else { return }  // no source content above 24.5 kHz
    let worst = m.stopband.max { $0.levelDB < $1.levelDB }!
    report("STOPBAND \(rate)->48k worst \(fmt(worst.levelDB)) dB @ \(Int(worst.freq)) Hz")
    for p in m.stopband { report("  \(rate) \(Int(p.freq)) Hz \(fmt(p.levelDB)) dB") }
    #expect(worst.levelDB < -100, "\(rate): \(worst.levelDB) dB from \(worst.freq) Hz")
}

@Test(arguments: rates)
func delayIsConstantWithinOneSample(rate: Int) async throws {
    let m = try await Sweeps.shared.get(rate)
    let band = m.delays.filter { $0.freq <= 18_000 }.map(\.samples)
    let median = band.sorted()[band.count / 2]
    let spread = band.map { abs($0 - median) }.max()!
    let range = band.max()! - band.min()!
    report("DELAY \(rate)->48k median \(fmt(median)) samples, max dev \(fmt(spread)), range \(fmt(range))")
    for d in m.delays { report("  \(rate) \(Int(d.freq)) Hz \(fmt(d.samples)) smp") }
    #expect(spread <= 1, "\(rate): delay deviates \(spread) samples from median \(median)")
}

/// Control: the fit recovers a known gain and delay, so a flat 0 dB / 0-sample result above is a measurement of
/// the converter and not an artefact of the fit.
@Test func fitRecoversKnownGainAndDelay() {
    let f = 15_000.0
    let delay = 3.25
    let y = (0..<48_000).map { Float(0.45 * sin(2 * Double.pi * f * (Double($0) - delay) / Double(outRate))) }
    let (amp, phase) = fit(y, range: trimmedRange(y.count), freq: f)
    #expect(abs(20 * log10(amp / amplitude) - 20 * log10(0.9)) < 0.001)
    let w = 2 * Double.pi * f / Double(outRate)
    #expect(abs(-phase / w - delay) < 0.001 || abs(-phase / w + 2 * Double.pi / w - delay) < 0.001)
}

/// The measurements print only when `PF_SRC_REPORT` is set (for example `PF_SRC_REPORT=1 swift test --filter
/// SampleRateConverterQualityTests`), so a normal test run stays quiet.
private func report(_ line: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["PF_SRC_REPORT"] != nil { print(line()) }
}
