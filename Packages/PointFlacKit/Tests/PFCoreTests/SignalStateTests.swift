import Testing

@testable import PFCore

private func fmt(_ rate: Int, _ bits: Int, channels: Int = 2) -> AudioFormat {
    AudioFormat(sampleRate: rate, bitsPerSample: bits, channels: channels)
}

private func state(
    _ rate: Int, _ bits: Int, hardware: Int, int32: Bool = false, port: OutputPort = .usb("DAC"),
    processing: [String] = [], scrubbing: Bool = false, volume: Float? = 1.0, channels: Int = 2,
    hardwareChannels: Int? = 2
) -> SignalState {
    let source = fmt(rate, bits, channels: channels)
    return SignalState(
        source: source,
        plan: OutputFormatPolicy.plan(
            source: source, hardwareRate: hardware, capabilities: OutputCapabilities(int32Passthrough: int32)),
        hardwareRate: hardware, hardwareChannels: hardwareChannels, port: port, systemVolume: volume,
        activeProcessing: processing, scrubbing: scrubbing)
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
    state(44_100, 16, hardware: 44_100, port: .airPlay("Living Room")),
    state(44_100, 16, hardware: 44_100, port: .other("HDMI")),
    state(48_000, 24, hardware: 48_000, port: .wired("EarPods"), hardwareChannels: 1),
    SignalState(source: fmt(96_000, 24), port: .usb("DAC")),
    state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: 0.8),
    state(96_000, 32, hardware: 96_000, port: .bluetooth("AirPods")),
    state(96_000, 32, hardware: 96_000, processing: ["EQ"]),
    state(22_050, 16, hardware: 48_000, port: .wired("EarPods")),
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
    #expect(SignalStrip.text(allStates[9]) == "FLAC · 16-bit · 44.1 kHz · ● AirPlay (re-encoded)")
    #expect(SignalStrip.text(allStates[10]) == "FLAC · 16-bit · 44.1 kHz · ● Output may alter audio")
    #expect(SignalStrip.text(allStates[11]) == "FLAC · 24-bit · 48 kHz · ● Downmixed 2→1")
    #expect(SignalStrip.text(allStates[12]) == "FLAC · 24-bit · 96 kHz · ● Starting…")
    #expect(SignalStrip.text(allStates[13]) == "FLAC · 24-bit · 96 kHz · ● Pure · ● Volume 80%")
    #expect(SignalStrip.text(allStates[14]) == "FLAC · 32-bit · 96 kHz · ● Bluetooth (lossy)")
    #expect(SignalStrip.text(allStates[15]) == "FLAC · 32-bit · 96 kHz · ● Processing")
    #expect(SignalStrip.text(allStates[16]) == "FLAC · 16-bit · 48 kHz · ● Resampled 22.05→48")
}

@Test func indicatorPrecedence() {
    #expect(SignalState().indicator == .idle)
    #expect(allStates[0].indicator == .pure)
    #expect(allStates[1].indicator == .resampled(RateChange(from: 96_000, to: 48_000)))
    #expect(allStates[2].indicator == .depthReduced(from: 32, to: 24))
    #expect(allStates[3].indicator == .resampled(RateChange(from: 192_000, to: 48_000)))
    let everything = state(
        192_000, 32, hardware: 48_000, port: .bluetooth("X"), processing: ["EQ"], scrubbing: true,
        hardwareChannels: 1)
    #expect(everything.indicator == .scrubbing)
    var s = everything
    s.scrubbing = false
    #expect(s.indicator == .bluetoothLossy)
    s.port = .airPlay("TV")
    #expect(s.indicator == .airPlay)
    s.port = .other("HDMI")
    // A certain alteration (the downmix) outranks one that only may happen (an unknown route).
    #expect(s.indicator == .downmixed(from: 2, to: 1))
    s.hardwareChannels = 2
    #expect(s.indicator == .otherRoute)
    s.port = .usb("DAC")
    #expect(s.indicator == .processing(1))
    s.activeProcessing = []
    #expect(s.indicator == .resampled(RateChange(from: 192_000, to: 48_000)))
}

/// Every route that alters the audio outranks processing and everything below it, in one fixed order: Bluetooth,
/// AirPlay, a downmix, then a route of unknown kind.
@Test func routesThatAlterAudioOutrankProcessing() {
    for port in [OutputPort.bluetooth("X"), .airPlay("TV"), .other("CarPlay")] {
        let s = state(96_000, 24, hardware: 48_000, port: port, processing: ["EQ"])
        #expect(s.indicator != .processing(1), "\(port)")
        #expect(s.indicator != .pure, "\(port)")
    }
    let mono = state(96_000, 24, hardware: 96_000, port: .usb("DAC"), processing: ["EQ"], hardwareChannels: 1)
    #expect(mono.indicator == .downmixed(from: 2, to: 1))
    var bluetoothMono = mono
    bluetoothMono.port = .bluetooth("Headset")
    #expect(bluetoothMono.indicator == .bluetoothLossy)
    var airPlayMono = mono
    airPlayMono.port = .airPlay("TV")
    #expect(airPlayMono.indicator == .airPlay)
}

/// Wired, USB and the built-in route keep the plan's rules; a hardware side with as many channels as the source, or
/// more, or unknown, is no downmix.
@Test func faithfulRoutesKeepThePlanRules() {
    for port in [OutputPort.usb("DAC"), .wired("EarPods"), .builtIn] {
        #expect(state(96_000, 24, hardware: 96_000, port: port).indicator == .pure, "\(port)")
        #expect(state(96_000, 24, hardware: 96_000, port: port, hardwareChannels: 8).indicator == .pure)
        #expect(state(96_000, 24, hardware: 96_000, port: port, hardwareChannels: nil).indicator == .pure)
    }
    #expect(state(48_000, 16, hardware: 48_000, channels: 1, hardwareChannels: 1).indicator == .pure)
    #expect(state(48_000, 16, hardware: 48_000, channels: 1, hardwareChannels: 2).indicator == .pure)
}

/// "Pure" must be earned: a source with no plan yet is starting, whatever else is or is not known.
@Test func noPlanIsPendingNotPure() {
    var s = SignalState(source: fmt(48_000, 24), port: .usb("DAC"), systemVolume: 1)
    #expect(s.indicator == .pending)
    s.hardwareRate = 48_000
    #expect(s.indicator == .pending)
    // What is known without a plan still says so.
    s.port = .bluetooth("AirPods")
    #expect(s.indicator == .bluetoothLossy)
    s.port = .builtIn
    s.activeProcessing = ["EQ"]
    #expect(s.indicator == .processing(1))
    #expect(SignalStrip.label(.pending) == "● Starting…")
}

@Test func idleNeverReadsPure() {
    #expect(SignalStrip.label(.idle) == SignalStrip.idleText)
    #expect(SignalStrip.label(.idle) != SignalStrip.label(.pure))
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

/// Ledger T13: a 96 kHz track planned at 48 kHz (EarPods), with the hardware now back at 96 kHz (a DAC plugged in
/// while paused). The source and hardware rates match, but pointFlac still resamples to 48: the strip says that, never
/// "Resampled 96→96", and never "Pure".
@Test func neverShowsAResampleToTheSameRate() {
    var s = state(96_000, 24, hardware: 48_000, port: .wired("EarPods"))
    s.hardwareRate = 96_000
    #expect(s.indicator == .resampled(RateChange(from: 96_000, to: 48_000)))
    #expect(SignalStrip.text(s) == "FLAC · 24-bit · 96 kHz · ● Resampled 96→48")
    for s in allStates {
        if case .resampled(let change) = s.indicator {
            #expect(change.from != change.to, "\(s)")
        }
    }
    // A plan that claims a resample to the same rate is no resample either.
    let odd = SignalState(
        source: fmt(48_000, 24),
        plan: OutputPlan(
            client: .float32, clientSampleRate: 48_000, resample: RateChange(from: 48_000, to: 48_000),
            reduceTo24: false),
        hardwareRate: 48_000, port: .usb("DAC"))
    #expect(odd.indicator == .pure)
}

@Test func volumeWarningOnlyOnUSB() {
    #expect(state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: 0.8).volumeWarningPercent == 80)
    #expect(state(96_000, 24, hardware: 96_000, port: .builtIn, volume: 0.8).volumeWarningPercent == nil)
    #expect(state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: 1.0).volumeWarningPercent == nil)
    #expect(state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: nil).volumeWarningPercent == nil)
}

/// Spec §5.7: the volume warning sits next to whatever the state is, and only on USB below full scale.
@Test func stripShowsTheVolumeWarning() {
    #expect(
        SignalStrip.text(state(96_000, 24, hardware: 48_000, port: .usb("DAC"), volume: 0.5))
            == "FLAC · 24-bit · 48 kHz · ● Resampled 96→48 · ● Volume 50%")
    #expect(
        SignalStrip.text(SignalState(source: fmt(96_000, 24), port: .usb("DAC"), systemVolume: 0.25))
            == "FLAC · 24-bit · 96 kHz · ● Starting… · ● Volume 25%")
    #expect(!SignalStrip.text(state(96_000, 24, hardware: 96_000, port: .builtIn, volume: 0.5)).contains("Volume"))
    #expect(!SignalStrip.text(state(96_000, 24, hardware: 96_000, port: .usb("DAC"), volume: 1)).contains("Volume"))
    #expect(SignalStrip.text(SignalState(port: .usb("DAC"), systemVolume: 0.5)) == "No record")
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

/// Only an untouched path reads "Pure": no state above that alters the audio, or is not known yet, says it.
@Test func pureOnlyWhenNothingAltersTheAudio() {
    let pure = allStates.filter { SignalStrip.text($0).contains("Pure") }
    for s in pure {
        #expect(s.indicator == .pure)
        #expect(s.plan != nil && s.plan?.resample == nil && s.plan?.reduceTo24 == false)
        #expect(s.hardwareRate == s.plan?.clientSampleRate)
        #expect(s.activeProcessing.isEmpty && !s.scrubbing)
        switch s.port {
        case .usb, .wired, .builtIn: break
        default: Issue.record("Pure on \(String(describing: s.port))")
        }
    }
}

@Test func resolutionTable() {
    #expect(SignalStrip.badges(state(96_000, 24, hardware: 96_000)) == ["HI-RES 24/96", "PURE"])
    #expect(SignalStrip.badges(state(192_000, 24, hardware: 48_000, port: .builtIn)) == ["LOSSLESS 24/48"])
    #expect(
        SignalStrip.badges(state(44_100, 16, hardware: 44_100, port: .wired("EarPods"))) == [
            "LOSSLESS 16/44.1", "PURE",
        ])
    #expect(SignalStrip.badges(state(96_000, 24, hardware: 96_000, port: .bluetooth("AirPods"))).isEmpty)
    #expect(SignalStrip.badges(state(96_000, 24, hardware: 96_000, processing: ["EQ"])) == ["HI-RES 24/96"])
    #expect(SignalStrip.badges(state(192_000, 32, hardware: 192_000)) == ["HI-RES 24/192"])
    // Int32 client delivers 32 bits.
    #expect(
        state(192_000, 32, hardware: 192_000, int32: true).resolution == .hiRes(bits: 32, rate: 192_000))
    #expect(state(96_000, 24, hardware: 96_000, port: .airPlay("TV")).resolution == .lossy)
    #expect(SignalState().resolution == nil)
    #expect(SignalStrip.badges(SignalState()).isEmpty)
    #expect(SignalStrip.badges(state(88_200, 24, hardware: 88_200)) == ["HI-RES 24/88.2", "PURE"])
    #expect(SignalStrip.badges(state(96_000, 16, hardware: 96_000)) == ["LOSSLESS 16/96", "PURE"])
    #expect(SignalStrip.badges(state(192_000, 32, hardware: 192_000, int32: true)) == ["HI-RES 32/192", "PURE"])
    // HDMI/CarPlay: no claim; the strip already says the output may alter the audio.
    #expect(SignalStrip.badges(state(96_000, 24, hardware: 96_000, port: .other("HDMI"))).isEmpty)
    // Downmixed: PCM is still delivered, so the resolution pill stays, and Pure does not.
    #expect(
        SignalStrip.badges(state(96_000, 24, hardware: 96_000, port: .wired("Mono"), hardwareChannels: 1))
            == ["HI-RES 24/96"])
}

@Test func titleNoteTable() {
    #expect(SignalStrip.titleNote(state(96_000, 24, hardware: 48_000, port: .builtIn)) == "Resampled 96→48")
    #expect(SignalStrip.titleNote(state(96_000, 32, hardware: 96_000)) == "32→24-bit")
    #expect(SignalStrip.titleNote(state(96_000, 24, hardware: 96_000, processing: ["EQ"])) == "Processing")
    #expect(
        SignalStrip.titleNote(
            state(48_000, 24, hardware: 48_000, port: .wired("Mono"), channels: 6, hardwareChannels: 2))
            == "Downmixed 6→2")
    #expect(SignalStrip.titleNote(state(96_000, 24, hardware: 96_000, scrubbing: true)) == "Scrubbing")
    #expect(SignalStrip.titleNote(state(96_000, 24, hardware: 96_000)) == nil)
    #expect(SignalStrip.titleNote(state(96_000, 24, hardware: 96_000, port: .bluetooth("AirPods"))) == nil)
    #expect(SignalStrip.titleNote(state(44_100, 16, hardware: 44_100, port: .airPlay("TV"))) == nil)
    #expect(SignalStrip.titleNote(state(44_100, 16, hardware: 44_100, port: .other("HDMI"))) == nil)
    #expect(SignalStrip.titleNote(SignalState()) == nil)
    #expect(SignalStrip.titleNote(SignalState(source: fmt(96_000, 24), port: .usb("DAC"))) == nil)
}
