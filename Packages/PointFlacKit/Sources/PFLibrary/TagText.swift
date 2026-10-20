import Foundation

/// Tag text as the library stores and shows it.
///
/// Tags are untrusted input (spec §5.8): a file can carry a 16 MiB title, control characters, a NUL, or nothing but
/// spaces. Each value is cleaned once, at import: control characters become spaces, invisible format characters go, whitespace runs collapse, the
/// ends are trimmed, and the result is capped at `maxCharacters`, so no tag can blow up a row, the search index or a
/// layout. An empty result counts as no tag.
enum TagText {
    /// Longer than any real title (the longest classical titles run to about 300 characters).
    static let maxCharacters = 512

    static func clean(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        var count = 0
        for scalar in raw.unicodeScalars {
            let category = scalar.properties.generalCategory
            // Invisible format characters (a BOM, a zero-width space) go, except the joiners that shape emoji and
            // Indic scripts.
            if category == .format && scalar.value != 0x200C && scalar.value != 0x200D { continue }
            if scalar.properties.isWhitespace || category == .control {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(scalar)
            count += 1
            // Scalars, not characters: cheap, and close enough for a cap.
            if count >= maxCharacters { break }
        }
        return out.isEmpty ? nil : String(out)
    }
}
