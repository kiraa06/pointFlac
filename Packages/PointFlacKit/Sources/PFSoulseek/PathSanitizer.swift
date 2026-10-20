import CryptoKit
import Foundation

/// Turns remote Soulseek paths into local names.
///
/// Remote paths never become local paths (§5.6). Only a sanitised base name is used, inside a per-transfer folder whose
/// name is a hash, so `..`, absolute paths, separators and control characters from a hostile peer cannot escape the
/// staging directory.
public enum PathSanitizer {
    static let maxNameBytes = 180

    /// The last component of a backslash- or slash-separated remote path, cleaned for local use.
    public static func localFileName(forRemotePath path: String) -> String {
        let components = path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        var name = String(components.last ?? "")
        name = String(
            name.unicodeScalars.map { scalar -> Character in
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar == ":" { return "_" }
                return Character(scalar)
            })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)

        var stem = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, name[dot...].utf8.count <= 16 {
            stem = String(name[..<dot])
            ext = String(name[dot...]).lowercased()
        }
        if stem.isEmpty { stem = "track" }
        let budget = maxNameBytes - ext.utf8.count
        while stem.utf8.count > budget, !stem.isEmpty { stem.removeLast() }
        return stem + ext
    }

    /// Everything before the last separator, for grouping results by folder.
    public static func remoteFolder(of path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "" }
        return String(path[..<index])
    }

    /// A per-transfer folder name derived from the peer and the remote path. Deterministic, so an interrupted download
    /// finds its `.part` file again and resumes by offset.
    static func transferFolderName(peer: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(peer)\u{0}\(path)".utf8))
        return "slsk-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
