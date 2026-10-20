import Testing

@testable import PFCore

private func fmt(_ rate: Int, _ bits: Int) -> AudioFormat {
    AudioFormat(sampleRate: rate, bitsPerSample: bits, channels: 2)
}

private func state(
    _ rate: Int, _ bits: Int, hardware: Int, int32: Bool = false, port: OutputPort = .usb("DAC"),
    processing: [String] = [], scrubbing: Bool = false, volume: Float? = 1.0
) -> SignalState {
    let source = fmt(rate, bits)
    return SignalState(
        source: source,
        plan: OutputFormatPolicy.plan(
            source: source, hardwareRate: hardware, capabilities: OutputCapabilities(int32Passthrough: int32)),
        hardwareRate: hardware, port: port, systemVolume: volume, activeProcessing: processing,
        scrubbing: scrubbing)
}

private let allStates: [SignalState] = [
    state(96_000, 24, hardware: 96_000),
    state(96_000, 24, hardware: 48_000),
    state(96_000, 32, hardware: 96_000),
    state(192_000, 32, hardware: 48_000),
    state(96_000, 24, hardware: 96_000, port: .bluetooth("AirPods")),
    state(96_000, 24, hardware: 96_000, scrubbing: true),
    state(96_000, 24, hardware: 96_000, processing: ["EQ"]),
    state(44_100, 16, hardware: 44_100, port: .builtIn, volume: 0.8),
    SignalState(),
]

@Test func stripTexts() {
    #expect(SignalStrip.text(allStates[0]) == "FLAC · 24-bit · 96 kHz · ● Pure")
    #expect(SignalStrip.text(allStates[1]) == "FLAC · 24-bit · 48 kHz · ● Resampled 96→48")
    #expect(SignalStrip.text(allStates[2]) == "FLAC · 32-bit · 96 kHz · ● 32→24-bit")
    #expect(SignalStrip.text(allStates[3]) == "FLAC · 32-bit · 48 kHz · ● Resampled 192→48")
    #expect(SignalStrip.text(allStates[4]) == "FLAC · 24-bit · 96 kHz · ● Bluetooth (lossy)")
    #expect(SignalStrip.text(allStates[5]) == "FLAC · 24-bit · 96 kHz · ● Scrubbing")
    #expect(SignalStrip.text(allStates[6]) == "FLAC · 24-bit · 96 kHz · ● Processing")
    #expect(SignalStrip.text(allStates[7]) == "FLAC · 16-bit · 44.1 kHz · ● Pure")
    #expect(SignalStrip.text(allStates[8]) == "No record")
}

@Test func indicatorPrecedence() {
    #expect(SignalState().indicator == .idle)
    #expect(allStates[0].indicator == .pure)
    #expect(allStates[1].indicator == .resampled(RateChange(from: 96_000, to: 48_000)))
    #expect(allStates[2].indicator == .depthReduced(from: 32, to: 24))
    #expect(allStates[3].indicator == .resampled(RateChange(from: 192_000, to: 48_000)))
    let everything = state(
        192_000, 32, hardware: 48_000, port: .bluetooth("X"), processing: ["EQ"], scrubbing: true)
    #expect(everything.indicator == .scrubbing)
    var s = everything
    s.scrubbing = false
    #expect(s.indicator == .bluetoothLossy)
    s.port = .usb("DAC")
    #expect(s.indicator == .processing(1))
    s.activeProcessing = []
    #expect(s.indicator == .resampled(RateChange(from: 192_000, to: 48_000)))
}

/// Ruling R17: the hardware runs at a rate other than the unit's client rate, so iOS resamples after pointFlac. The
/// strip must not say "Pure" then, whatever the plan says.
@Test func resamplingAfterTheUnitIsShown() {
    var s = state(44_100, 16, hardware: 44_100)
    #expect(s.indicator == .pure)
    s.hardwareRate = 48_000
    #expect(s.indicator == .resampled(RateChange(from: 44_100, to: 48_000)))
    #expect(SignalStrip.text(s) == "FLAC · 16-bit · 48 kHz · ● Resampled 44.1→48")
    // Below processing in precedence…
    s.activeProcessing = ["EQ"]
    #expect(s.indicator == .processing(1))
    // …and above the plan's own resampling and depth reduction.
    var resampled = state(96_000, 24, hardware: 48_000)
    resampled.hardwareRate = 44_100
    #expect(resampled.indicator == .resampled(RateChange(from: 96_000, to: 44_100)))
    var deep = state(96_000, 32, hardware: 96_000)
    deep.hardwareRate = 48_000
    #expect(deep.indicator == .resampled(RateChange(from: 96_000, to: 48_000)))
}

@Test func volumeWarningOnlyOnUSB() {
    #expect(state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: 0.8).volumeWarningPercent == 80)
    #expect(state(96_000, 24, hardware: 96_000, port: .builtIn, volume: 0.8).volumeWarningPercent == nil)
    #expect(state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: 1.0).volumeWarningPercent == nil)
    #expect(state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: nil).volumeWarningPercent == nil)
}

@Test func outputPortPredicates() {
    #expect(OutputPort.usb("x").isUSB)
    #expect(!OutputPort.builtIn.isUSB)
    #expect(OutputPort.bluetooth("x").isBluetooth)
    #expect(!OutputPort.wired("x").isBluetooth)
}

@Test func neverSaysBitPerfect() {
    for s in allStates {
        #expect(!SignalStrip.text(s).lowercased().contains("bit-perfect"))
    }
}
