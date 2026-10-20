import Foundation

/// The licence an Archive item is offered under, when it is one pointFlac may show (spec §4.7, licence filter).
///
/// Only Creative Commons licences, public-domain marks, and the Live Music Archive (`etree`, whose bands allow
/// trading) pass. Everything else, including an item with no licence data, is hidden: some Archive uploads are
/// commercial albums, and the review argument in spec §3.1 depends on never offering them.
public struct ArchiveLicence: Sendable, Hashable {
    /// A short name for the record, e.g. "CC BY-NC-SA 4.0" or "CC0 1.0".
    public var name: String
    /// The licence deed, for a "view licence" link.
    public var url: String

    /// The Creative Commons licence codes that exist. NC and ND are open licences in the spec's sense and stay
    /// admitted; the UI labels them. Anything else under `/licenses/` is not a licence pointFlac recognises.
    static let creativeCommonsCodes: Set<String> = [
        "by", "by-sa", "by-nd", "by-nc", "by-nc-sa", "by-nc-nd", "sampling", "sampling+", "nc-sampling+",
        "devnations", "publicdomain",
    ]

    static let etree = ArchiveLicence(
        name: "Live Music Archive (trading permitted)", url: "https://archive.org/details/etree")

    /// Classifies an item from its `licenseurl` and `collection` metadata; `nil` means "do not show".
    public static func classify(licenseURL: String?, collections: [String]) -> ArchiveLicence? {
        if let licenseURL, let licence = creativeCommons(licenseURL) { return licence }
        if collections.contains(where: { $0.lowercased() == "etree" }) { return .etree }
        return nil
    }

    /// Parses creativecommons.org deed URLs: `/licenses/<code>/<version>[/<jurisdiction>]` and the public-domain
    /// tools under `/publicdomain/`.
    static func creativeCommons(_ raw: String) -> ArchiveLicence? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host()?.lowercased(), host == "creativecommons.org" || host == "www.creativecommons.org"
        else { return nil }
        let parts = url.path().lowercased().split(separator: "/").map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.+-")
        guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        let canonical = "https://creativecommons.org/" + parts.joined(separator: "/") + "/"

        switch parts.first {
        case "publicdomain":
            switch parts.dropFirst().first {
            case "zero": return ArchiveLicence(name: "CC0 \(parts.dropFirst(2).first ?? "1.0")", url: canonical)
            case "mark":
                return ArchiveLicence(name: "Public Domain Mark \(parts.dropFirst(2).first ?? "1.0")", url: canonical)
            default: return ArchiveLicence(name: "Public domain", url: canonical)
            }
        case "licenses":
            guard parts.count >= 2 else { return nil }
            let code = parts[1]
            if code == "publicdomain" { return ArchiveLicence(name: "Public domain", url: canonical) }
            guard creativeCommonsCodes.contains(code) else { return nil }
            let name = (["CC", code.uppercased()] + parts.dropFirst(2).prefix(2).map { $0.uppercased() })
                .joined(separator: " ")
            return ArchiveLicence(name: name, url: canonical)
        default:
            return nil
        }
    }
}
