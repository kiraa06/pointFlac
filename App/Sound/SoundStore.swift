import Foundation
import Observation
import PFAudio
import PFDSP
import QuartzCore
import SwiftUI

/// The Sound tab's state (spec §4.8): the settings its controls show, saved in Application Support as `sound.json`
/// and played through `Player.setSound`.
///
/// ## Pure and the blocks
/// `SoundSettings.pure` bypasses every block without touching the blocks' own switches. So turning Pure on keeps
/// each block's state, and turning it off brings back exactly the blocks that were on before.
///
/// ## Throttling
/// Every edit lands in `settings` at once, clamped, so the controls follow the finger. The player gets the latest
/// value at most once per display frame (`FrameGate`): all the changes a drag makes between two frames compile one
/// chain, and no backlog builds up. A compile costs about 1.2 ms in Debug on the main actor (Task 7), and each new
/// chain cross-fades in over 10 ms, so the gate runs at up to 60 Hz and one fade is over before the next begins.
///
/// Saving waits for half a second without a change, so a drag writes the file once, when the finger stops. `flush()`
/// applies and saves at once, for when the app leaves the foreground.
@MainActor
@Observable
final class SoundStore {
    /// What the controls show, clamped. The player is at most a display frame behind it.
    private(set) var settings: SoundSettings
    /// One stable id per parametric band, parallel to `settings.eq.bands`, so the band rows and handles keep their
    /// identity: a deleted row animates away as itself, not as the last one.
    private(set) var bandIDs: [UUID] = []

    @ObservationIgnored private let player: Player
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let gate = FrameGate()
    /// The ReplayGain and crossfade modes their switches turn back on: the last one chosen, else Track and Between
    /// albums. Turning a block off sets its mode to Off, so the mode it had is kept here (for this launch).
    private(set) var lastReplayGainMode: ReplayGainMode = .track
    private(set) var lastCrossfadeMode: CrossfadeMode = .betweenAlbums

    /// What the player was last given.
    @ObservationIgnored private var applied: SoundSettings
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var unsaved = false

    /// How long a save waits for the edits to stop.
    @ObservationIgnored private let saveDelay: Duration

    /// Loads the saved settings and gives them to the player at once, so the first pipeline plays with them.
    init(
        player: Player, fileURL: URL = SoundStore.defaultFileURL, saveDelay: Duration = .milliseconds(500)
    ) {
        self.player = player
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        let loaded = Self.load(from: fileURL)
        settings = loaded
        applied = loaded
        bandIDs = loaded.eq.bands.map { _ in UUID() }
        if loaded.replayGain.mode != .off { lastReplayGainMode = loaded.replayGain.mode }
        if loaded.crossfade.mode != .off { lastCrossfadeMode = loaded.crossfade.mode }
        player.setSound(loaded)
        gate.action = { [weak self] in self?.applyNow() }
    }

    /// `Application Support/sound.json`.
    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "sound.json")
    }

    /// The saved settings, through `SoundSettings.decode`: a missing, corrupt or newer-format file loads as Pure.
    nonisolated static func load(from url: URL) -> SoundSettings {
        guard let data = try? Data(contentsOf: url) else { return SoundSettings() }
        return SoundSettings.decode(data).clamped()
    }

    // MARK: Editing

    /// Applies `edit`, clamps the result, and schedules the player update and the save. A no-op edit does neither.
    func update(_ edit: (inout SoundSettings) -> Void) {
        var next = settings
        edit(&next)
        next = next.clamped()
        guard next != settings else { return }
        settings = next
        matchBandIDs()
        gate.request()
        scheduleSave()
    }

    /// New ids for bands added at the end, and none for bands gone from it. Deletions in the middle and wholesale
    /// replacements fix the ids themselves first.
    private func matchBandIDs() {
        let count = settings.eq.bands.count
        if bandIDs.count < count {
            bandIDs += (bandIDs.count..<count).map { _ in UUID() }
        } else if bandIDs.count > count {
            bandIDs.removeLast(bandIDs.count - count)
        }
    }

    /// A binding to one value of the settings, for a control.
    func binding<Value>(_ path: WritableKeyPath<SoundSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: path] },
            set: { value in self.update { $0[keyPath: path] = value } })
    }

    func setPure(_ on: Bool) {
        update { $0.pure = on }
    }

    func setBlock(_ block: SoundBlock, on: Bool) {
        switch block {
        case .replayGain: setReplayGainMode(on ? lastReplayGainMode : .off)
        case .crossfade: setCrossfadeMode(on ? lastCrossfadeMode : .off)
        default: update { block.set(on, in: &$0) }
        }
    }

    /// Off, or the mode to level by; a mode other than Off is the one the switch turns back on.
    func setReplayGainMode(_ mode: ReplayGainMode) {
        if mode != .off { lastReplayGainMode = mode }
        update { $0.replayGain.mode = mode }
    }

    func setCrossfadeMode(_ mode: CrossfadeMode) {
        if mode != .off { lastCrossfadeMode = mode }
        update { $0.crossfade.mode = mode }
    }

    /// Whether a headphone correction has been chosen: only then has its switch anything to play.
    var hasCorrection: Bool { !settings.correction.bands.isEmpty }

    /// Plays `correction` (an OPRA preset or an imported AutoEq file) in place of any earlier one, switched on:
    /// choosing headphones means wanting to hear them corrected. Clamped like every edit, so a preset's band below
    /// 20 Hz plays at 20 Hz.
    func applyCorrection(_ correction: CorrectionSettings) {
        update {
            $0.correction = correction
            $0.correction.enabled = true
        }
    }

    /// Loads an `EQPresets` curve into the graphic EQ and switches the EQ on: choosing a preset means wanting to hear
    /// it. The parametric bands are kept, so switching back to Parametric finds them as they were.
    func applyPreset(_ name: String) {
        guard let preset = EQPresets.all.first(where: { $0.name == name }) else { return }
        update {
            $0.eq.mode = .graphic
            $0.eq.graphicGainsDb = preset.gainsDb
            $0.eq.presetName = preset.name
            $0.eq.enabled = true
        }
    }

    /// One graphic slider. The preset name follows: a preset's name while the gains still match it, else Custom.
    func setGraphicGain(_ index: Int, _ db: Double) {
        update {
            guard $0.eq.graphicGainsDb.indices.contains(index) else { return }
            $0.eq.graphicGainsDb[index] = db
            $0.eq.presetName = Self.presetName(for: $0.eq.graphicGainsDb)
        }
    }

    static func presetName(for gains: [Double]) -> String {
        EQPresets.all.first { $0.gainsDb == gains }?.name ?? "Custom"
    }

    func setBand(_ index: Int, _ band: EQBand) {
        update {
            guard $0.eq.bands.indices.contains(index) else { return }
            $0.eq.bands[index] = band
        }
    }

    /// Adds a band (a 0 dB peak in the widest free stretch of the spectrum, unless one is given) and returns its
    /// index, or nil when the EQ already has the most bands `clamped()` keeps.
    @discardableResult
    func addBand(_ band: EQBand? = nil) -> Int? {
        guard settings.eq.bands.count < SoundRanges.maxBands else { return nil }
        let new = band ?? Self.freeBand(among: settings.eq.bands)
        update { $0.eq.bands.append(new) }
        return settings.eq.bands.count - 1
    }

    /// Deletes a band. Pure makes the EQ inert, so it deletes nothing then.
    func removeBand(at index: Int) {
        guard !settings.pure, settings.eq.bands.indices.contains(index) else { return }
        bandIDs.remove(at: index)
        update { $0.eq.bands.remove(at: index) }
    }

    /// The graphic EQ's ten peaks as parametric bands, to fine-tune a preset.
    func copyGraphicToBands() {
        bandIDs = []
        update {
            var graphic = $0.eq
            graphic.mode = .graphic
            $0.eq.bands = graphic.effectiveBands
            $0.eq.mode = .parametric
        }
        // Even when the edit changed nothing (so `update` skipped it), the ids must match the bands again.
        matchBandIDs()
    }

    /// Runout's warmth curve (spec §4.8, item 5): bass +2, treble −1.5, tilt −1, with Tone on.
    func applyWarmth() {
        update { $0.tone = ToneSettings(enabled: true, bassDb: 2, trebleDb: -1.5, tiltDb: -1) }
    }

    func flattenTone() {
        update {
            $0.tone.bassDb = 0
            $0.tone.trebleDb = 0
            $0.tone.tiltDb = 0
        }
    }

    /// A 0 dB peak, Q 1, in the middle (in octaves) of the widest gap between the bands and the ends of the range.
    static func freeBand(among bands: [EQBand]) -> EQBand {
        let range = SoundRanges.bandFrequency
        guard !bands.isEmpty else { return EQBand(type: .peak, frequency: 1000, gainDb: 0, q: 1) }
        let marks = ([range.lowerBound, range.upperBound] + bands.map(\.frequency)).map(log2).sorted()
        var best = (gap: -1.0, middle: log2(1000.0))
        for (a, b) in zip(marks, marks.dropFirst()) where b - a > best.gap {
            best = (b - a, (a + b) / 2)
        }
        return EQBand(type: .peak, frequency: SoundFormat.rounded(pow(2, best.middle)), gainDb: 0, q: 1)
    }

    // MARK: Applying and saving

    /// Gives the player the latest settings now, and saves them if a save is pending.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        applyNow()
        if unsaved { save() }
    }

    private func applyNow() {
        guard settings != applied else { return }
        applied = settings
        player.setSound(settings)
    }

    private func scheduleSave() {
        unsaved = true
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(settings)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            unsaved = false
        } catch {
            // The settings still play; the next change, or the next flush, tries the write again.
            unsaved = true
        }
    }

    #if DEBUG
        /// UI-test launch arguments, applied before the store loads: `-PFResetSound` deletes the saved settings, so
        /// the launch starts from Pure defaults; `-PFCorruptSound` saves a file that only a lenient reader would take
        /// (Pure off and the EQ on, under an unknown EQ mode), to show it loads as Pure. (`-PFSoundSaveDelay <s>`, read
        /// by `AppModel`, stretches the save's debounce, so a test can show that only the flush wrote.)
        static func prepareForLaunch(arguments: [String], fileURL: URL = defaultFileURL) {
            if arguments.contains("-PFResetSound") {
                try? FileManager.default.removeItem(at: fileURL)
            }
            if arguments.contains("-PFCorruptSound") {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(#"{"pure":false,"eq":{"enabled":true,"mode":"bogus"}}"#.utf8).write(to: fileURL)
            }
        }
    #endif
}

/// Runs an action on the next display frame, once, however many times it was asked for in between: the latest state
/// wins and nothing queues. At most 60 times a second (see `SoundStore`). The display link holds the gate only weakly,
/// through a proxy, and the gate invalidates the link when it goes, so neither outlives its store.
@MainActor
final class FrameGate {
    var action: () -> Void = {}
    private var link: CADisplayLink?

    func request() {
        if let link {
            link.isPaused = false
            return
        }
        let link = CADisplayLink(target: FrameProxy(self), selector: #selector(FrameProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    fileprivate func tick() {
        link?.isPaused = true
        action()
    }

    isolated deinit {
        link?.invalidate()
    }
}

/// The display link's target, which it retains: a weak hop back to the gate.
@MainActor
private final class FrameProxy: NSObject {
    weak var gate: FrameGate?

    init(_ gate: FrameGate) {
        self.gate = gate
    }

    @objc func tick() {
        gate?.tick()
    }
}

/// The blocks the Sound tab shows, in chain order (`SoundSettings.activeBlockNames`): ReplayGain and the preamp, then
/// headphone correction, the EQ, tone and crossfeed, the limiter, and crossfade last. Each case brings its capsule in
/// the flow row and its section in the list, which puts the EQ first (`pageOrder`).
enum SoundBlock: String, CaseIterable, Identifiable {
    case replayGain, preamp, correction, eq, tone, crossfeed, limiter, crossfade

    var id: Self { self }

    /// The chain's own name, as `activeBlockNames` and the signal details list it.
    var name: String {
        switch self {
        case .replayGain: "ReplayGain"
        case .preamp: "Preamp"
        case .correction: "Headphone correction"
        case .eq: "EQ"
        case .tone: "Tone"
        case .crossfeed: "Crossfeed"
        case .limiter: "Limiter"
        case .crossfade: "Crossfade"
        }
    }

    /// The flow capsule's word: the name, short enough for the row.
    var capsuleName: String { self == .correction ? "Correction" : name }

    /// The order of the Sound tab's sections (rulings R4-UI-a and R4-UI-b): the EQ first, as the block used most, then
    /// the other tonal blocks (tone, headphone correction, crossfeed), then the ones set once (ReplayGain, the preamp,
    /// the limiter, crossfade). The flow row and the Pure card keep chain order (`allCases`), since they describe the
    /// signal path. Every block appears exactly once (checked in Debug builds), so a new one cannot go missing.
    static let pageOrder: [SoundBlock] = {
        let order: [SoundBlock] = [.eq, .tone, .correction, .crossfeed, .replayGain, .preamp, .limiter, .crossfade]
        assert(order.count == allCases.count && Set(order) == Set(allCases), "pageOrder must list every block once")
        return order
    }()

    /// The block in a sentence: "Show headphone correction settings".
    var settingsName: String {
        switch self {
        case .eq, .replayGain: name
        default: name.lowercased()
        }
    }

    /// The limiter and the preamp have no switch: the limiter joins the chain whenever another block is on, and the
    /// preamp whenever its trim is not 0 dB (its automatic headroom runs with any chain).
    var isSwitchable: Bool { self != .limiter && self != .preamp }

    /// The block's own state, whatever Pure says. The limiter's is whether any other block is on; the preamp's,
    /// whether it trims.
    func isOn(in s: SoundSettings) -> Bool {
        switch self {
        case .replayGain: return s.replayGain.mode != .off
        case .preamp: return s.preamp.trimDb != 0
        case .correction: return s.correction.enabled
        case .eq: return s.eq.enabled
        case .tone: return s.tone.enabled
        case .crossfeed: return s.crossfeed.enabled
        case .crossfade: return s.crossfade.mode != .off
        case .limiter:
            var unbypassed = s
            unbypassed.pure = false
            return unbypassed.activeBlockNames.contains(name)
        }
    }

    /// Whether the block is in the chain now: on, and Pure off.
    func isActive(in s: SoundSettings) -> Bool {
        s.activeBlockNames.contains(name)
    }

    /// A switchable block's state for VoiceOver, else what the block is doing: "Running" or "Standby" for the limiter,
    /// the trim for the preamp.
    func spokenState(in s: SoundSettings) -> String {
        switch self {
        case .limiter: return isActive(in: s) ? "Running" : "Standby"
        case .preamp: return isOn(in: s) ? "Trim \(SoundFormat.gainSpoken(s.preamp.trimDb))" : "No trim"
        default: return isOn(in: s) ? "On" : "Off"
        }
    }

    /// Switches the block, with a mode for the blocks that have one (`SoundStore.setBlock` brings back the last mode
    /// chosen instead).
    func set(_ on: Bool, in s: inout SoundSettings) {
        switch self {
        case .replayGain: s.replayGain.mode = on ? (s.replayGain.mode == .off ? .track : s.replayGain.mode) : .off
        case .correction: s.correction.enabled = on
        case .eq: s.eq.enabled = on
        case .tone: s.tone.enabled = on
        case .crossfeed: s.crossfeed.enabled = on
        case .crossfade: s.crossfade.mode = on ? (s.crossfade.mode == .off ? .betweenAlbums : s.crossfade.mode) : .off
        case .preamp, .limiter: break
        }
    }
}

/// Every control's range, read from `SoundSettings.clamped()` itself (each value pushed past both ends and clamped
/// back), so no control can reach a value the chain would refuse.
enum SoundRanges {
    private static func range(
        _ set: (inout SoundSettings, Double) -> Void, _ get: (SoundSettings) -> Double
    ) -> ClosedRange<Double> {
        var low = SoundSettings()
        set(&low, -.greatestFiniteMagnitude)
        var high = SoundSettings()
        set(&high, .greatestFiniteMagnitude)
        return get(low.clamped())...get(high.clamped())
    }

    private static func band(_ set: @escaping (inout EQBand, Double) -> Void, _ get: @escaping (EQBand) -> Double)
        -> ClosedRange<Double>
    {
        range(
            { s, v in
                var b = EQBand(type: .peak, frequency: 1000, gainDb: 0, q: 1)
                set(&b, v)
                s.eq.bands = [b]
            }, { get($0.eq.bands[0]) })
    }

    static let graphicGain = range({ $0.eq.graphicGainsDb[0] = $1 }, { $0.eq.graphicGainsDb[0] })
    static let bandFrequency = band({ $0.frequency = $1 }, \.frequency)
    static let bandGain = band({ $0.gainDb = $1 }, \.gainDb)
    static let bandQ = band({ $0.q = $1 }, \.q)
    static let bass = range({ $0.tone.bassDb = $1 }, \.tone.bassDb)
    static let treble = range({ $0.tone.trebleDb = $1 }, \.tone.trebleDb)
    static let tilt = range({ $0.tone.tiltDb = $1 }, \.tone.tiltDb)
    static let ceiling = range({ $0.limiter.ceilingDbTP = $1 }, \.limiter.ceilingDbTP)
    static let replayGainPreamp = range({ $0.replayGain.preampDb = $1 }, \.replayGain.preampDb)
    static let trim = range({ $0.preamp.trimDb = $1 }, \.preamp.trimDb)
    static let crossfadeSeconds = range({ $0.crossfade.seconds = $1 }, \.crossfade.seconds)
    /// The most parametric bands `clamped()` keeps.
    static let maxBands: Int = {
        var s = SoundSettings()
        s.eq.bands = Array(repeating: EQBand(type: .peak, frequency: 1000, gainDb: 0, q: 1), count: 1000)
        return s.clamped().eq.bands.count
    }()
    /// The graphic EQ's band centres, in hertz.
    static let graphicCentres: [Double] = EQSettings(mode: .graphic).effectiveBands.map(\.frequency)
}
