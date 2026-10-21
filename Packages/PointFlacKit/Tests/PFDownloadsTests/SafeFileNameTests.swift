import Testing

@testable import PFDownloads

@Suite("SafeFileName")
struct SafeFileNameTests {
    @Test(
        "remote paths collapse to a base name that cannot leave its folder",
        arguments: [
            ("../../etc/passwd.flac", "passwd.flac"),
            ("..\\..\\Windows\\evil.flac", "evil.flac"),
            ("@@user\\Music\\Album\\01 - Intro.flac", "01 - Intro.flac"),
            ("/absolute/path/Track.FLAC", "Track.flac"),
            ("...hidden.flac", "hidden.flac"),
            ("  spaced  .flac  ", "spaced.flac"),
            ("na\u{0}me\u{7}:x.flac", "namex.flac"),
            ("evil\u{202E}calf.flac", "evilcalf.flac"),
        ])
    func sanitises(input: String, expected: String) {
        #expect(SafeFileName.sanitize(input) == expected)
    }

    @Test(
        "anything that is not a .flac name is refused",
        arguments: ["song.mp3", "song.flac.exe", "", "..", "/", "x.fla", ".flac"])
    func refusesNonFlac(input: String) {
        #expect(SafeFileName.sanitize(input) == nil)
    }

    @Test("decomposed Unicode is normalised to NFC")
    func normalises() {
        #expect(SafeFileName.sanitize("Cafe\u{301}.flac") == "Caf\u{E9}.flac")
    }

    @Test("overlong names are cut on a character boundary and keep the extension")
    func truncates() throws {
        let name = try #require(SafeFileName.sanitize(String(repeating: "é", count: 300) + ".flac"))
        #expect(name.utf8.count <= SafeFileName.maxBytes)
        #expect(name.hasSuffix(".flac"))
        #expect(name.hasPrefix("éé"))
    }

    @Test(
        "a separator hidden in a grapheme cluster with a combining mark still splits the path",
        arguments: [
            "x/\u{301}../\u{301}evil.flac", "a/\u{301}b.flac", "a\\\u{301}b.flac", "a:\u{301}b.flac", "/\u{301}.flac",
        ])
    func combiningMarkSeparators(input: String) throws {
        let name = try #require(SafeFileName.sanitize(input))
        #expect(!name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0 == ":" })
        #expect(name.unicodeScalars.first != ".")
        #expect(name.hasSuffix(".flac"))
    }

    @Test("a single grapheme cluster too long to keep falls back to a visible name, never a bare .flac")
    func oversizedCluster() {
        let cluster = "e" + String(repeating: "\u{301}", count: 300)
        #expect(SafeFileName.sanitize(cluster + ".flac") == "track.flac")
        #expect(SafeFileName.sanitize(String(repeating: "\u{301}", count: 300) + ".flac") == "track.flac")
    }

    @Test("dots and spaces in any order cannot produce a hidden file")
    func noHiddenNames() {
        #expect(SafeFileName.sanitize(".. .x.flac") == "x.flac")
        #expect(SafeFileName.sanitize(" . .flac") == "track.flac")
    }
}
