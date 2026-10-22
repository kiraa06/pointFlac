import Foundation
import Testing

@testable import PFDSP

/// Per-device Sound settings (Task 15): what each output plays, how a new one starts, and how the file reads back,
/// leniently, as `sound.json` does.
@Suite("Per-device sound profiles")
struct SoundProfilesTests {
    static let dac = "usb:Test DAC"
    static let speaker = "builtIn"

    static var eqOn: SoundSettings {
        var s = SoundSettings()
        s.pure = false
        s.eq.enabled = true
        s.eq.graphicGainsDb = EQPresets.all[1].gainsDb
        return s
    }

    @Test("off, every output plays the current settings and nothing is recorded")
    func offSharesTheSettings() {
        var p = SoundProfiles()
        #expect(p.settings(for: Self.dac, current: Self.eqOn) == Self.eqOn)
        p.record(Self.eqOn, for: Self.dac)
        #expect(p.profiles.isEmpty)
    }

    @Test("on, a new output starts from the current settings, and a known one gets its own back")
    func onSwitchesWithTheDevice() {
        var p = SoundProfiles()
        p.enable(for: Self.dac, current: SoundSettings())
        // The speaker is new: it starts from what the DAC plays now.
        #expect(p.settings(for: Self.speaker, current: SoundSettings()) == SoundSettings())
        #expect(p.profiles[Self.speaker] == SoundSettings())
        // The EQ goes on for the DAC.
        p.record(Self.eqOn, for: Self.dac)
        #expect(p.settings(for: Self.speaker, current: Self.eqOn) == SoundSettings())
        #expect(p.settings(for: Self.dac, current: SoundSettings()) == Self.eqOn)
    }

    @Test("Pure is part of each output's settings")
    func pureIsPerDevice() {
        var p = SoundProfiles()
        var processed = SoundSettings()
        processed.pure = false
        p.enable(for: Self.dac, current: processed)
        p.record(SoundSettings(), for: Self.speaker)
        #expect(p.settings(for: Self.speaker, current: processed).pure)
        #expect(!p.settings(for: Self.dac, current: SoundSettings()).pure)
    }

    @Test("switching on takes the current settings for the output in use; off keeps every profile for next time")
    func enableAndDisable() {
        var p = SoundProfiles()
        p.enable(for: Self.dac, current: Self.eqOn)
        p.record(SoundSettings(), for: Self.speaker)
        p.disable()
        #expect(!p.useProfiles)
        #expect(p.profiles.count == 2)
        // On again from the speaker: it takes what plays now; the DAC keeps its own.
        p.enable(for: Self.speaker, current: Self.eqOn)
        #expect(p.profiles[Self.speaker] == Self.eqOn)
        #expect(p.profiles[Self.dac] == Self.eqOn)
    }

    @Test("forget drops an output's settings; the next time it appears it starts from the current settings")
    func forget() {
        var p = SoundProfiles()
        p.enable(for: Self.dac, current: Self.eqOn)
        p.record(SoundSettings(), for: Self.speaker)
        p.forget(Self.speaker)
        #expect(p.profiles[Self.speaker] == nil)
        #expect(p.settings(for: Self.speaker, current: Self.eqOn) == Self.eqOn)
    }

    @Test("settings are kept clamped, as everything the player gets")
    func clamped() {
        var p = SoundProfiles()
        var wild = Self.eqOn
        wild.preamp.trimDb = 99
        p.enable(for: Self.dac, current: wild)
        #expect(p.profiles[Self.dac]?.preamp.trimDb == 12)
    }

    @Test("an existing single-settings file becomes the profile of the output in use, with profiles still off")
    func migration() {
        let p = SoundProfiles.migrated(from: Self.eqOn, for: Self.dac)
        #expect(!p.useProfiles)
        #expect(p.profiles == [Self.dac: Self.eqOn])
    }

    @Test("the file round-trips")
    func roundTrip() throws {
        var p = SoundProfiles()
        p.enable(for: Self.dac, current: Self.eqOn)
        p.record(SoundSettings(), for: Self.speaker)
        let data = try JSONEncoder().encode(p)
        #expect(SoundProfiles.decode(data) == p)
    }

    @Test("a corrupt file loads as no profiles, switched off; one unreadable profile loads as Pure, the rest intact")
    func corruptFiles() throws {
        #expect(SoundProfiles.decode(Data("not json".utf8)) == SoundProfiles())
        #expect(SoundProfiles.decode(Data(#"{"useProfiles":"yes"}"#.utf8)) == SoundProfiles())
        let good = String(decoding: try JSONEncoder().encode(Self.eqOn), as: UTF8.self)
        let bad = #"{"pure":false,"eq":{"enabled":true,"mode":"bogus"}}"#
        let json = #"{"useProfiles":true,"profiles":{"usb:Test DAC":\#(good),"builtIn":\#(bad)}}"#
        let p = SoundProfiles.decode(Data(json.utf8))
        #expect(p.useProfiles)
        #expect(p.profiles[Self.dac] == Self.eqOn)
        #expect(p.profiles[Self.speaker] == SoundSettings())
        // A file from before profiles' switch existed, or with nothing in it, reads as off.
        #expect(SoundProfiles.decode(Data("{}".utf8)) == SoundProfiles())
    }
}
