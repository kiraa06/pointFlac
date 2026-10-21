import Foundation

/// Reads a `ParametricEQ.txt` the user picked (AutoEq's, or any file in Equalizer APO's layout) into a headphone
/// correction, refusing anything that is not one before it is read in full.
///
/// Blocking file I/O: call it off the main actor.
public enum AutoEqImport {
    /// Far larger than any real ParametricEQ file (a few hundred bytes), and small enough to read at once.
    public static let maxBytes = 256 * 1024

    /// Why a file was refused.
    public enum Failure: Error, Equatable, Sendable {
        /// It could not be opened or read; the system's reason.
        case unreadable(String)
        /// Larger than `maxBytes`.
        case tooLarge
        /// Neither UTF-8 nor UTF-16 text.
        case notText
        /// The parser cannot read line `number` (1-based), quoted trimmed and cut to 80 characters.
        case unsupportedLine(number: Int, text: String)
        /// More than `AutoEqParser.maxBands` filters are on.
        case tooManyBands
        /// No filter is on.
        case noFilters
    }

    /// The file at `url` as a correction, switched on, named after the file and credited to it
    /// (`CorrectionSource.autoEq`). Its size is checked before anything is read, and the read is bounded as well, for
    /// a provider that reports no size. Security-scoped access, which a Files-picker URL needs, starts and stops here.
    public static func correction(contentsOf url: URL) -> Result<CorrectionSettings, Failure> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            return .failure(.tooLarge)
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        return correction(data: data, fileName: url.lastPathComponent)
    }

    /// `data`, the contents of a file named `fileName`, as a correction.
    public static func correction(data: Data, fileName: String) -> Result<CorrectionSettings, Failure> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let text = text(from: data) else { return .failure(.notText) }
        do {
            let parsed = try AutoEqParser.parse(text)
            guard !parsed.bands.isEmpty else { return .failure(.noFilters) }
            return .success(
                CorrectionSettings(
                    enabled: true, name: name(fromFileName: fileName), author: "", source: .autoEq(fileName: fileName),
                    preampDb: parsed.preampDb, bands: parsed.bands))
        } catch AutoEqParser.ParseError.unsupportedLine(let number) {
            return .failure(.unsupportedLine(number: number, text: line(number, of: text)))
        } catch AutoEqParser.ParseError.tooManyBands {
            return .failure(.tooManyBands)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// UTF-16 with its byte-order mark, as some Windows editors save; else UTF-8, whose mark the parser skips.
    public static func text(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Line `number` of `text` as the parser numbers it (a leading byte-order mark is not a line of its own), trimmed
    /// and cut to 80 characters; empty when there is no such line.
    static func line(_ number: Int, of text: String) -> String {
        let body = text.first == "\u{FEFF}" ? text.dropFirst() : Substring(text)
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard number >= 1, number <= lines.count else { return "" }
        return String(lines[number - 1].trimmingCharacters(in: .whitespaces).prefix(80))
    }

    /// "Sennheiser HD 600 ParametricEQ.txt" → "Sennheiser HD 600".
    public static func name(fromFileName fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        for suffix in [" ParametricEQ", " Parametric EQ", "_ParametricEQ", "-ParametricEQ"]
        where name.lowercased().hasSuffix(suffix.lowercased()) {
            name.removeLast(suffix.count)
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Imported correction" : name
    }
}
