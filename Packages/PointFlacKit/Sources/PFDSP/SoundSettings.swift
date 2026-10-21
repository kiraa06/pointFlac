import Foundation

/// How ReplayGain picks the loudness a track is levelled to.
public enum ReplayGainMode: String, Codable, CaseIterable, Sendable {
    case off, track, album
}

/// Whether the equaliser is ten fixed sliders or a list of free bands.
public enum EQMode: String, Codable, CaseIterable, Sendable {
    case graphic, parametric
}

/// When the end of one track overlaps the start of the next.
public enum CrossfadeMode: String, Codable, CaseIterable, Sendable {
    case off, betweenAlbums, always
}

/// The three well-known crossfeed tunings. Each is a (low-pass cut, feed level) pair, so the filter needs no free
/// parameters and the UI offers a choice rather than two knobs.
public enum CrossfeedPreset: String, Codable, CaseIterable, Sendable {
    case defaultBS2B, chuMoy, janMeier

    public var parameters: (cutHz: Double, feedDb: Double) {
        switch self {
        case .defaultBS2B: (700, 4.5)
        case .chuMoy: (700, 6.0)
        case .janMeier: (650, 9.5)
        }
    }
}

/// Where a headphone correction came from. Kept so the UI can credit it and so a re-import can find the original.
public enum CorrectionSource: Equatable, Sendable {
    case none
    case opra(id: String)
    case autoEq(fileName: String)
}

extension CorrectionSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id, fileName }
    private enum Kind: String, Codable { case none, opra, autoEq }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .none: self = .none
        case .opra: self = .opra(id: try c.decode(String.self, forKey: .id))
        case .autoEq: self = .autoEq(fileName: try c.decode(String.self, forKey: .fileName))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode(Kind.none, forKey: .kind)
        case .opra(let id):
            try c.encode(Kind.opra, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .autoEq(let fileName):
            try c.encode(Kind.autoEq, forKey: .kind)
            try c.encode(fileName, forKey: .fileName)
        }
    }
}

/// One filter of an equaliser or correction curve.
public struct EQBand: Codable, Equatable, Sendable {
    public var type: FilterType
    public var frequency: Double
    public var gainDb: Double
    public var q: Double
    public var enabled: Bool

    public init(type: FilterType, frequency: Double, gainDb: Double, q: Double, enabled: Bool = true) {
        self.type = type
        self.frequency = frequency
        self.gainDb = gainDb
        self.q = q
        self.enabled = enabled
    }
}

public struct ReplayGainSettings: Codable, Equatable, Sendable {
    public var mode: ReplayGainMode = .off
    /// −15…15 dB.
    public var preampDb = 0.0
    public var preventClipping = true
    public var referenceLufs = -18.0

    public init(
        mode: ReplayGainMode = .off, preampDb: Double = 0, preventClipping: Bool = true, referenceLufs: Double = -18
    ) {
        self.mode = mode
        self.preampDb = preampDb
        self.preventClipping = preventClipping
        self.referenceLufs = referenceLufs
    }
}

public struct PreampSettings: Codable, Equatable, Sendable {
    public var autoHeadroom = true
    /// −24…12 dB.
    public var trimDb = 0.0

    public init(autoHeadroom: Bool = true, trimDb: Double = 0) {
        self.autoHeadroom = autoHeadroom
        self.trimDb = trimDb
    }
}

public struct CorrectionSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var name = ""
    public var author = ""
    public var source: CorrectionSource = .none
    public var preampDb = 0.0
    public var bands: [EQBand] = []

    public init(
        enabled: Bool = false, name: String = "", author: String = "", source: CorrectionSource = .none,
        preampDb: Double = 0, bands: [EQBand] = []
    ) {
        self.enabled = enabled
        self.name = name
        self.author = author
        self.source = source
        self.preampDb = preampDb
        self.bands = bands
    }
}

public struct EQSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var mode: EQMode = .graphic
    public var graphicGainsDb = [Double](repeating: 0, count: 10)
    public var bands: [EQBand] = []
    public var presetName = "Flat"

    public init(
        enabled: Bool = false, mode: EQMode = .graphic,
        graphicGainsDb: [Double] = [Double](repeating: 0, count: 10), bands: [EQBand] = [],
        presetName: String = "Flat"
    ) {
        self.enabled = enabled
        self.mode = mode
        self.graphicGainsDb = graphicGainsDb
        self.bands = bands
        self.presetName = presetName
    }

    /// ISO octave centres of the graphic equaliser.
    static let graphicCentres: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// The bands the filter chain actually runs: ten peaks for the graphic sliders, the free list otherwise.
    public var effectiveBands: [EQBand] {
        switch mode {
        case .graphic:
            Self.graphicCentres.enumerated().map { i, hz in
                let g = i < graphicGainsDb.count ? graphicGainsDb[i] : 0
                return EQBand(type: .peak, frequency: hz, gainDb: min(max(g, -12), 12), q: 1.41)
            }
        case .parametric:
            bands
        }
    }
}

public struct ToneSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var bassDb = 0.0
    public var trebleDb = 0.0
    public var tiltDb = 0.0

    public init(enabled: Bool = false, bassDb: Double = 0, trebleDb: Double = 0, tiltDb: Double = 0) {
        self.enabled = enabled
        self.bassDb = bassDb
        self.trebleDb = trebleDb
        self.tiltDb = tiltDb
    }

    /// Bass and treble shelves plus tilt, which pivots the spectrum around 1 kHz as two opposed shelves.
    public var effectiveBands: [EQBand] {
        [
            EQBand(type: .lowShelf, frequency: 100, gainDb: bassDb, q: 0.707),
            EQBand(type: .highShelf, frequency: 10_000, gainDb: trebleDb, q: 0.707),
            EQBand(type: .lowShelf, frequency: 1000, gainDb: -tiltDb / 2, q: 0.5),
            EQBand(type: .highShelf, frequency: 1000, gainDb: tiltDb / 2, q: 0.5),
        ]
    }
}

public struct CrossfeedSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var preset: CrossfeedPreset = .defaultBS2B

    public init(enabled: Bool = false, preset: CrossfeedPreset = .defaultBS2B) {
        self.enabled = enabled
        self.preset = preset
    }
}

public struct LimiterSettings: Codable, Equatable, Sendable {
    /// −3…0 dBTP.
    public var ceilingDbTP = -0.3

    public init(ceilingDbTP: Double = -0.3) {
        self.ceilingDbTP = ceilingDbTP
    }
}

public struct CrossfadeSettings: Codable, Equatable, Sendable {
    public var mode: CrossfadeMode = .off
    /// 1…12 s.
    public var seconds = 6.0

    public init(mode: CrossfadeMode = .off, seconds: Double = 6) {
        self.mode = mode
        self.seconds = seconds
    }
}

/// Everything the Sound section controls. `pure` bypasses every block, so the default is bit-perfect output.
public struct SoundSettings: Codable, Equatable, Sendable {
    public var pure = true
    public var replayGain = ReplayGainSettings()
    public var preamp = PreampSettings()
    public var correction = CorrectionSettings()
    public var eq = EQSettings()
    public var tone = ToneSettings()
    public var crossfeed = CrossfeedSettings()
    public var limiter = LimiterSettings()
    public var crossfade = CrossfadeSettings()

    public init() {}

    /// Decodes saved settings, falling back to Pure defaults on anything unreadable (an unknown raw value from a
    /// newer build, a corrupt file) so a bad save can never stop playback or change the sound unexpectedly.
    public static func decode(_ data: Data) -> SoundSettings {
        (try? JSONDecoder().decode(SoundSettings.self, from: data)) ?? SoundSettings()
    }

    /// The blocks that are on, in chain order. Empty when Pure. The limiter joins whenever anything else is on,
    /// because every gain stage can push past full scale.
    public var activeBlockNames: [String] {
        guard !pure else { return [] }
        var names: [String] = []
        if replayGain.mode != .off { names.append("ReplayGain") }
        if preamp.trimDb != 0 { names.append("Preamp") }
        if correction.enabled { names.append("Headphone correction") }
        if eq.enabled { names.append("EQ") }
        if tone.enabled { names.append("Tone") }
        if crossfeed.enabled { names.append("Crossfeed") }
        if crossfade.mode != .off { names.append("Crossfade") }
        if !names.isEmpty {
            // Limiter sits before Crossfade in the chain, so insert it ahead of that block.
            let at = names.last == "Crossfade" ? names.count - 1 : names.count
            names.insert("Limiter", at: at)
        }
        return names
    }

    /// Every range from the model, applied. Run after any edit or import so the audio thread never sees a value
    /// outside what the filters were designed for.
    public func clamped() -> SoundSettings {
        func c(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        func band(_ b: EQBand) -> EQBand {
            EQBand(
                type: b.type, frequency: c(b.frequency, 20, 20_000), gainDb: c(b.gainDb, -24, 24),
                q: c(b.q, 0.1, 20), enabled: b.enabled)
        }
        var s = self
        s.replayGain.preampDb = c(s.replayGain.preampDb, -15, 15)
        s.preamp.trimDb = c(s.preamp.trimDb, -24, 12)
        s.correction.bands = s.correction.bands.map(band)
        s.eq.bands = Array(s.eq.bands.prefix(20)).map(band)
        var gains = Array(s.eq.graphicGainsDb.prefix(10)).map { c($0, -12, 12) }
        gains += [Double](repeating: 0, count: 10 - gains.count)
        s.eq.graphicGainsDb = gains
        s.tone.bassDb = c(s.tone.bassDb, -12, 12)
        s.tone.trebleDb = c(s.tone.trebleDb, -12, 12)
        s.tone.tiltDb = c(s.tone.tiltDb, -12, 12)
        s.limiter.ceilingDbTP = c(s.limiter.ceilingDbTP, -3, 0)
        s.crossfade.seconds = c(s.crossfade.seconds, 1, 12)
        return s
    }
}

/// Starting points for the graphic equaliser, ten gains in dB from 31.5 Hz to 16 kHz.
public enum EQPresets {
    public static let all: [(name: String, gainsDb: [Double])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 0, 1, 3, 5, 6]),
        ("Vocal", [-2, -1, 0, 1, 3, 3, 2, 1, 0, -1]),
        ("Loudness", [5, 4, 2, 0, -1, 0, 0, 1, 3, 4]),
        ("Warmth", [2, 2, 1.5, 1, 0, 0, -0.5, -1, -1.5, -2]),
        ("Acoustic", [3, 2, 1, 0, 1, 1, 2, 2, 1, 0]),
    ]
}
