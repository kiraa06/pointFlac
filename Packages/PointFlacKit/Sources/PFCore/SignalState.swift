import Foundation

public enum SignalIndicator: Equatable, Sendable {
    /// Nothing to describe: no track.
    case idle
    /// A track is on its way, but its output plan is not negotiated yet, so nothing about the path is known.
    case pending
    case pure
    case resampled(RateChange)
    case depthReduced(from: Int, to: Int)
    case processing(Int)
    case scrubbing
    case bluetoothLossy
    /// AirPlay re-encodes for the receiver, commonly to 16-bit 44.1 kHz ALAC, whatever pointFlac hands it.
    case airPlay
    /// The source has more channels than the hardware side, so the system mixes them down.
    case downmixed(from: Int, to: Int)
    /// A route of a kind pointFlac knows nothing about (CarPlay, HDMI, an unknown port): it may alter the audio.
    case otherRoute
}

/// What the hardware is handed, as Apple Music draws the line: Hi-Res is at least 24 bits at a rate above 48 kHz,
/// Lossless is anything at or below it, and a lossy route is neither.
public enum DeliveredResolution: Equatable, Sendable {
    case hiRes(bits: Int, rate: Int)
    case lossless(bits: Int, rate: Int)
    case lossy
}

/// Everything the signal strip needs to describe, honestly, what happens to the audio.
public struct SignalState: Sendable, Equatable {
    public var source: AudioFormat?
    public var plan: OutputPlan?
    /// The rate the hardware actually runs at, as far as pointFlac can tell: the output unit's hardware side when it
    /// reports one, otherwise the negotiated client rate. Set together with `plan`, from the same negotiation. When it
    /// differs from `plan.clientSampleRate`, iOS is resampling after pointFlac's output, and `indicator` says so.
    public var hardwareRate: Int?
    /// The channel count of the output unit's hardware side, when it reports one. Set together with `plan`. Fewer
    /// channels than the source means the system downmixes after pointFlac (stereo into a mono route).
    public var hardwareChannels: Int?
    public var port: OutputPort?
    public var systemVolume: Float?
    public var activeProcessing: [String]
    public var scrubbing: Bool

    public init(
        source: AudioFormat? = nil, plan: OutputPlan? = nil, hardwareRate: Int? = nil, hardwareChannels: Int? = nil,
        port: OutputPort? = nil, systemVolume: Float? = nil, activeProcessing: [String] = [], scrubbing: Bool = false
    ) {
        self.source = source
        self.plan = plan
        self.hardwareRate = hardwareRate
        self.hardwareChannels = hardwareChannels
        self.port = port
        self.systemVolume = systemVolume
        self.activeProcessing = activeProcessing
        self.scrubbing = scrubbing
    }

    /// What the strip says about the path. The central rule: never `.pure` while anything alters the audio or while
    /// the path is not known yet. Precedence, highest first:
    ///
    /// 1. `scrubbing`.
    /// 2. The routes and layouts that alter the audio whatever pointFlac does, in this fixed order: `bluetoothLossy`,
    ///    `airPlay`, `downmixed`, `otherRoute`. A lossy re-encode first, then a re-encode, then a definite downmix,
    ///    then a route that only *may* alter the audio, so a certain alteration is never hidden behind a possible one.
    /// 3. `processing`.
    /// 4. `pending`: no plan yet. It sits below the route, the downmix and processing, which are known without a plan
    ///    and still say so; everything below it needs the plan.
    /// 5. Resampled after the unit: `hardwareRate` differs from `plan.clientSampleRate`, shown as source → hardware
    ///    rate. It outranks the plan, so the strip never says "Pure" while the system resamples behind pointFlac.
    /// 6. Resampled by pointFlac (`plan.resample`).
    /// 7. `depthReduced`.
    /// 8. `pure`.
    ///
    /// A rate change from a rate to itself is no change and is never shown. After the unit, that happens when the
    /// hardware is back at the source rate under a plan that still resamples (a DAC plugged in while paused on a plan
    /// made for EarPods): the plan's own resample, which is real, is shown instead.
    public var indicator: SignalIndicator {
        guard let source else { return .idle }
        if scrubbing { return .scrubbing }
        if let route = routeIndicator(for: source) { return route }
        if !activeProcessing.isEmpty { return .processing(activeProcessing.count) }
        guard let plan else { return .pending }
        if let hardwareRate, hardwareRate != plan.clientSampleRate, hardwareRate != source.sampleRate {
            return .resampled(RateChange(from: source.sampleRate, to: hardwareRate))
        }
        if let change = plan.resample, change.from != change.to { return .resampled(change) }
        if plan.reduceTo24 { return .depthReduced(from: source.bitsPerSample, to: 24) }
        return .pure
    }

    /// The route and channel-layout indicators, in their fixed order, or nil when the route keeps the plan's rules
    /// (USB, wired, built-in, with enough hardware channels).
    private func routeIndicator(for source: AudioFormat) -> SignalIndicator? {
        switch port {
        case .bluetooth: return .bluetoothLossy
        case .airPlay: return .airPlay
        default: break
        }
        if let hardwareChannels, hardwareChannels > 0, source.channels > hardwareChannels {
            return .downmixed(from: source.channels, to: hardwareChannels)
        }
        if case .other = port { return .otherRoute }
        return nil
    }

    /// What reaches the output, never just what the file holds: nil with no plan, `.lossy` over Bluetooth or AirPlay,
    /// otherwise the delivered depth (32 on an Int32 client, 24 when pointFlac reduces to 24, else the source's depth
    /// capped at 24) and rate (the hardware's, else the negotiated client rate). Hi-Res is at least 24 bits above
    /// 48 kHz (ruling R4-3).
    public var resolution: DeliveredResolution? {
        guard let plan else { return nil }
        switch port {
        case .bluetooth, .airPlay: return .lossy
        // A route pointFlac knows nothing about (HDMI, CarPlay): the strip says it may alter the audio, so no
        // Hi-Res or Lossless claim is made for it either.
        case .other: return nil
        default: break
        }
        let bits: Int
        if plan.client == .int32 {
            bits = 32
        } else if plan.reduceTo24 {
            bits = 24
        } else {
            bits = min(source?.bitsPerSample ?? 24, 24)
        }
        let rate = hardwareRate ?? plan.clientSampleRate
        return bits >= 24 && rate > 48_000 ? .hiRes(bits: bits, rate: rate) : .lossless(bits: bits, rate: rate)
    }

    /// Set only for a USB port with the system volume below full scale.
    public var volumeWarningPercent: Int? {
        guard port?.isUSB == true, let volume = systemVolume, volume < 1.0 else { return nil }
        return Int((volume * 100).rounded())
    }
}
