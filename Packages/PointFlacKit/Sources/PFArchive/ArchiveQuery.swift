import Foundation
import PFDownloads

/// Builds Archive search queries that cannot be widened by what the user types.
enum ArchiveQuery {
    /// The filters every search carries. They only narrow the server's answer; the licence and file-list checks on
    /// the client remain the real gate, because the item-level `format` field also matches zipped or derived FLAC.
    static let filters =
        "mediatype:audio AND format:(Flac OR \"24bit Flac\")"
        + " AND (licenseurl:*creativecommons.org* OR collection:etree)"

    /// Fields the search returns per item.
    static let fields = ["identifier", "title", "creator", "licenseurl", "collection"]

    /// The full Lucene query for a user's search text, or `nil` when nothing searchable is left.
    static func build(_ userText: String) -> String? {
        let terms = words(userText).map { "\"\($0)\"" }
        guard !terms.isEmpty else { return nil }
        return "(\(terms.joined(separator: " "))) AND \(filters)"
    }

    /// Splits search text into plain words, each later sent as a quoted term so Lucene reads it as text.
    ///
    /// Backslash escaping is not enough: the Archive's backend fails on `\-`, and on `/` even inside quotes. So
    /// anything but letters, digits, marks and `-`, `'`, `.`, `_` separates words, which also removes every
    /// operator character; `AND`, `OR` and `NOT` inside quotes are plain words.
    static func words(_ text: String) -> [String] {
        let keep = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: "-'._"))
        let separated = String(String.UnicodeScalarView(text.unicodeScalars.map { keep.contains($0) ? $0 : " " }))
        return SafeFileName.components(of: separated, separators: [" "]).filter { !$0.isEmpty }
            .map { String($0.prefix(64)) }.prefix(16).map { $0 }
    }

    /// `https://archive.org/advancedsearch.php?...`, most-downloaded first so the first page is the useful one.
    ///
    /// Spec §4.7 names the scrape API, but on 2026-10-21 it answered a new query with the cached result of an
    /// earlier one whenever the other parameters matched, so interactive search uses advanced search. Its
    /// 10,000-result ceiling does not matter for a first page of `rows` items.
    static func searchURL(base: URL, query: String, rows: Int) -> URL? {
        var components = URLComponents(url: base.appending(path: "advancedsearch.php"), resolvingAgainstBaseURL: false)
        components?.queryItems =
            [URLQueryItem(name: "q", value: query)]
            + fields.map { URLQueryItem(name: "fl[]", value: $0) }
            + [
                URLQueryItem(name: "sort[]", value: "downloads desc"),
                URLQueryItem(name: "rows", value: String(min(max(1, rows), 500))),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "output", value: "json"),
            ]
        // URLComponents leaves "+" alone, which servers read as a space.
        let encoded = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encoded
        return components?.url
    }

    /// Archive identifiers are ASCII letters, digits, `.`, `-` and `_`; anything else is refused before it
    /// becomes part of a URL.
    static func isValidIdentifier(_ identifier: String) -> Bool {
        guard let first = identifier.unicodeScalars.first, identifier.utf8.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return CharacterSet.alphanumerics.contains(first) && identifier.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// `https://archive.org/metadata/<identifier>`.
    static func metadataURL(base: URL, identifier: String) -> URL? {
        guard isValidIdentifier(identifier) else { return nil }
        return base.appending(path: "metadata").appending(path: identifier)
    }

    /// `https://archive.org/download/<identifier>/<path>`, each path segment percent-encoded.
    static func downloadURL(base: URL, identifier: String, path: String) -> URL? {
        guard isValidIdentifier(identifier), ArchiveFileSelector.isSafePath(path) else { return nil }
        let unreserved = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = SafeFileName.components(of: path, separators: ["/"]).compactMap {
            $0.addingPercentEncoding(withAllowedCharacters: unreserved)
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/download/\(identifier)/" + encoded.joined(separator: "/")
        return components?.url
    }
}
