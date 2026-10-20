import Foundation

/// One entry of the generated fixture manifest (`scripts/make-fixtures.py`).
public struct Fixture: Sendable, Decodable {
    public enum Expectation: String, Sendable, Decodable {
        case accept
        case reject
    }

    public let name: String
    public let file: String
    public let raw: String?
    public let sampleRate: Int
    public let bits: Int
    public let channels: Int
    public let frames: Int64
    public let expect: Expectation
    /// Exact `FlacRejection` case name for rejected fixtures.
    public let rejection: String?
    public let hasMD5: Bool
    public let multichannel: Bool
}

public enum Fixtures {
    private static let directory: URL = {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            fatalError("PFTestSupport: Fixtures resource directory missing")
        }
        return url
    }()

    public static let all: [Fixture] = {
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            return try JSONDecoder().decode([Fixture].self, from: data)
        } catch {
            fatalError("PFTestSupport: cannot load fixture manifest: \(error)")
        }
    }()

    public static func url(_ f: Fixture) -> URL {
        directory.appendingPathComponent(f.file)
    }

    /// Interleaved ground-truth samples, native range, decoded from the little-endian `.raw` file.
    public static func rawSamples(_ f: Fixture) -> [Int32] {
        guard let raw = f.raw else { return [] }
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent(raw), options: .alwaysMapped)
            return data.withUnsafeBytes { buf in
                (0..<(buf.count / 4)).map {
                    Int32(littleEndian: buf.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self))
                }
            }
        } catch {
            fatalError("PFTestSupport: cannot read \(raw): \(error)")
        }
    }

    public static func named(_ name: String) -> Fixture {
        guard let f = all.first(where: { $0.name == name }) else {
            fatalError("PFTestSupport: no fixture named \(name)")
        }
        return f
    }
}
