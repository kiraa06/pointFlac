import Foundation

/// Per-device Sound settings (Task 15): each output (a USB DAC, wired headphones, a Bluetooth headset, the built-in
/// speaker) keeps its own `SoundSettings`, Pure included, under its `OutputPort.profileKey`, and the Sound tab switches
/// to them when the route changes.
///
/// - **Off** (the default), every output shares one set of settings, and nothing is recorded per device.
/// - **Switching on** gives the output in use the settings playing now, so nothing changes at the switch. The other
///   outputs keep what they had, from an earlier time on or from the migration.
/// - **A new output**, seen for the first time while on, starts from the settings playing as it appears: plugging in
///   a DAC carries on with what was playing, and it is the DAC's own from then on.
/// - **Switching off** keeps every profile, so switching on again brings them back.
///
/// Saved next to `sound.json` (which keeps the settings in use, in its own format, so an older build still reads it).
/// The file is read leniently, as `sound.json` is: an unreadable file is no profiles, switched off, and an unreadable
/// profile is Pure defaults, so a bad save can never change the sound unexpectedly.
public struct SoundProfiles: Codable, Equatable, Sendable {
    public var useProfiles: Bool
    /// Each output's settings by profile key, clamped.
    public private(set) var profiles: [String: SoundSettings]

    public init(useProfiles: Bool = false, profiles: [String: SoundSettings] = [:]) {
        self.useProfiles = useProfiles
        self.profiles = profiles.mapValues { $0.clamped() }
    }

    /// The profiles of a build from before them: the settings in use, `settings`, become the profile of the output in
    /// use, `key`, since that is where they were set; profiles stay off, so nothing changes until they are switched on.
    public static func migrated(from settings: SoundSettings, for key: String) -> SoundProfiles {
        SoundProfiles(useProfiles: false, profiles: [key: settings])
    }

    /// Decodes saved profiles: an unreadable file is no profiles, switched off; an unreadable profile is Pure defaults.
    public static func decode(_ data: Data) -> SoundProfiles {
        (try? JSONDecoder().decode(SoundProfiles.self, from: data)) ?? SoundProfiles()
    }

    /// What the output `key` plays, given the settings playing now: with profiles on, its own, or for an output not
    /// seen before `current`, which becomes its own; with profiles off, `current`.
    public mutating func settings(for key: String, current: SoundSettings) -> SoundSettings {
        guard useProfiles else { return current }
        if let own = profiles[key] { return own }
        profiles[key] = current.clamped()
        return profiles[key] ?? current
    }

    /// Keeps `settings` as the output `key`'s own, while profiles are on.
    public mutating func record(_ settings: SoundSettings, for key: String) {
        guard useProfiles else { return }
        profiles[key] = settings.clamped()
    }

    /// Switches profiles on, with `current` as the output `key`'s own.
    public mutating func enable(for key: String, current: SoundSettings) {
        useProfiles = true
        profiles[key] = current.clamped()
    }

    /// Switches profiles off, keeping them for the next time they are switched on.
    public mutating func disable() {
        useProfiles = false
    }

    /// Drops the output `key`'s settings: next time it appears, it starts from the settings playing then.
    public mutating func forget(_ key: String) {
        profiles[key] = nil
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case useProfiles, profiles }

    /// One profile, read leniently: Pure defaults if it can't be read.
    private struct Lenient: Decodable {
        let settings: SoundSettings

        init(from decoder: Decoder) throws {
            settings = (try? SoundSettings(from: decoder))?.clamped() ?? SoundSettings()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        useProfiles = try c.decodeIfPresent(Bool.self, forKey: .useProfiles) ?? false
        profiles = try c.decodeIfPresent([String: Lenient].self, forKey: .profiles)?.mapValues(\.settings) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(useProfiles, forKey: .useProfiles)
        try c.encode(profiles, forKey: .profiles)
    }
}
