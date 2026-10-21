import Foundation

/// Turns a remote file name into a local one that cannot escape its folder.
///
/// Remote names come from strangers (an Archive uploader, a Soulseek peer), so a name is reduced to a single base
/// name before it is ever joined to a local path. Remote paths never become local paths (spec §5.6).
///
/// All splitting and filtering works on Unicode scalars, never on `Character`s: a separator followed by a combining
/// mark ("/\u{301}") is one grapheme cluster, so a `Character`-level split would miss the separator inside it.
public enum SafeFileName {
    /// Longest name produced, in UTF-8 bytes. APFS allows 255; the margin leaves room for a `.part` suffix.
    public static let maxBytes = 200

    /// Scalars that may never appear in a produced name: both path separators and the classic macOS one.
    static let forbidden: Set<Unicode.Scalar> = ["/", "\\", ":"]

    /// The sanitised base name, or `nil` when nothing usable is left or the name is not a `.flac` file.
    public static func sanitize(_ remote: String) -> String? {
        // Both separators: Soulseek paths are Windows-style, Archive paths are POSIX-style.
        let last = components(of: remote, separators: ["/", "\\"]).last { !$0.isEmpty } ?? ""
        var name = cleaned(last).precomposedStringWithCanonicalMapping
        // Normalisation never produces a separator, but the rule is cheap to enforce again on the final text.
        name = cleaned(name).trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading dots would make the file hidden, and "." or ".." are directory references.
        name = String(String.UnicodeScalarView(name.unicodeScalars.drop { $0 == "." }))
        guard name.lowercased().hasSuffix(".flac") else { return nil }

        // Dots and spaces are stripped from the stem's start until neither is left, so " .x.flac" cannot become
        // the hidden ".x.flac".
        let stem = String(
            String.UnicodeScalarView(
                String(name.dropLast(5)).unicodeScalars.drop {
                    $0 == "." || CharacterSet.whitespacesAndNewlines.contains($0)
                }
            )
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // The fallback comes after truncation: a single oversized grapheme cluster truncates to nothing.
        var safeStem = truncated(stem, toBytes: maxBytes - 5)
        if safeStem.isEmpty { safeStem = "track" }
        let result = safeStem + ".flac"
        guard !result.unicodeScalars.contains(where: forbidden.contains), result.unicodeScalars.first != "." else {
            return nil
        }
        return result
    }

    /// Splits `path` at the given separator scalars, keeping empty components.
    public static func components(of path: String, separators: Set<Unicode.Scalar>) -> [String] {
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if separators.contains(scalar) {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        parts.append(String(current))
        return parts
    }

    /// Removes control characters, the forbidden scalars, and Unicode bidi overrides that could disguise an
    /// extension in the UI ("evil\u{202E}calf.exe").
    private static func cleaned(_ text: String) -> String {
        String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter { scalar in
                    !CharacterSet.controlCharacters.contains(scalar) && !forbidden.contains(scalar)
                        && !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
                }))
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
