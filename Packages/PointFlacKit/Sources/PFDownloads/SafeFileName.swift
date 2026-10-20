import Foundation

/// Turns a remote file name into a local one that cannot escape its folder.
///
/// Remote names come from strangers (an Archive uploader, a Soulseek peer), so a name is reduced to a single base
/// name before it is ever joined to a local path. Remote paths never become local paths (spec §5.6).
public enum SafeFileName {
    /// Longest name produced, in UTF-8 bytes. APFS allows 255; the margin leaves room for a `.part` suffix.
    public static let maxBytes = 200

    /// The sanitised base name, or `nil` when nothing usable is left or the name is not a `.flac` file.
    public static func sanitize(_ remote: String) -> String? {
        // Both separators: Soulseek paths are Windows-style, Archive paths are POSIX-style.
        let lastComponent = remote.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = lastComponent.precomposedStringWithCanonicalMapping
        name = String(
            name.unicodeScalars.filter { scalar in
                // Control characters, the macOS path separator ":", and Unicode bidi overrides that could disguise
                // an extension in the UI ("evil\u{202E}calf.exe").
                !CharacterSet.controlCharacters.contains(scalar) && scalar != ":"
                    && !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
            }.map(Character.init))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading dots would make the file hidden, and "." or ".." are directory references.
        while name.hasPrefix(".") { name.removeFirst() }
        guard name.lowercased().hasSuffix(".flac") else { return nil }

        let stem = String(name.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        let safeStem = stem.isEmpty ? "track" : truncated(stem, toBytes: maxBytes - 5)
        return safeStem + ".flac"
    }

    /// Cuts `text` to at most `limit` UTF-8 bytes without splitting a character.
    private static func truncated(_ text: String, toBytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= limit else { break }
            result.append(character)
            used += size
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
