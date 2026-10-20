import Foundation
import PFDownloads

/// Picks the downloadable FLAC files out of an item's file list (spec §4.7).
///
/// The item-level search filter also matches zipped FLAC and derivatives, so the metadata file list is the source of
/// truth. A file is offered only if its format is `Flac` or `24bit Flac`, it is the uploader's `original`, its name
/// ends in `.flac`, its path is safe, and the listing gives the size and MD5 the download is checked against.
enum ArchiveFileSelector {
    static let flacFormats: Set<String> = ["flac", "24bit flac"]
    /// Some items are whole tape archives or sample libraries with thousands of FLAC files. An album fits easily;
    /// beyond this the rest of the item is left out so one result cannot flood the list.
    static let maxTracksPerItem = 300

    static func tracks(identifier: String, metadata: ItemMetadata?, files: [FileEntry], licence: ArchiveLicence)
        -> [RemoteTrack]
    {
        let itemTitle = metadata?.title?.first
        let itemCreator = metadata?.creator?.joined
        var selected: [(track: Int?, entry: FileEntry, size: Int64, md5: String)] = []
        for entry in files {
            guard let format = entry.format?.first?.lowercased(), flacFormats.contains(format),
                entry.source?.first?.lowercased() == "original",
                entry.name.lowercased().hasSuffix(".flac"), isSafePath(entry.name),
                let size = entry.size?.first.flatMap({ Int64($0) }), size > 0,
                let md5 = entry.md5?.first?.lowercased(), md5.count == 32, md5.allSatisfy(\.isHexDigit)
            else { continue }
            selected.append((trackNumber(entry.track?.first), entry, size, md5))
        }
        selected.sort { lhs, rhs in
            switch (lhs.track, rhs.track) {
            case (let l?, let r?) where l != r: l < r
            case (.some, .none): true
            case (.none, .some): false
            default: lhs.entry.name.localizedStandardCompare(rhs.entry.name) == .orderedAscending
            }
        }

        return selected.prefix(maxTracksPerItem).compactMap { track, entry, size, md5 in
            let baseName = entry.name.split(separator: "/").last.map(String.init) ?? entry.name
            guard SafeFileName.sanitize(baseName) != nil else { return nil }
            let stem = String(baseName.dropLast(5))
            var detail = [
                "identifier": identifier,
                "path": entry.name,
                "licence": licence.name,
                "licenceURL": licence.url,
                "md5": md5,
                "pageURL": "https://archive.org/details/\(identifier)",
            ]
            if let itemTitle { detail["itemTitle"] = itemTitle }
            if let track { detail["track"] = String(track) }
            if let length = entry.length?.first { detail["length"] = length }
            return RemoteTrack(
                id: "archive:\(identifier)/\(entry.name)",
                provider: ArchiveProvider.providerID,
                title: entry.title?.first ?? stem,
                artist: entry.artist?.first ?? entry.creator?.first ?? itemCreator,
                album: entry.album?.first ?? itemTitle,
                fileName: baseName,
                sizeBytes: size,
                // The Archive labels 24-bit files "24bit Flac"; plain "Flac" does not say its depth, so it stays
                // unknown rather than guessed.
                bitsPerSample: entry.format?.first?.lowercased() == "24bit flac" ? 24 : nil,
                sampleRate: nil,
                detail: detail)
        }
    }

    /// A relative path inside an item: no empty, `.` or `..` segments, no backslashes or control characters.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// "01", "1/12" or "A1" style track numbers; only the leading digits count.
    static func trackNumber(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.prefix(while: \.isNumber)
        return Int(digits)
    }
}
