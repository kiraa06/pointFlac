import Foundation

/// A metadata value that the Archive sends as a string, a number or an array of strings, depending on the item.
struct FlexibleStrings: Decodable, Sendable, Hashable {
    var values: [String]

    var first: String? { values.first { !$0.isEmpty } }
    var joined: String? { values.isEmpty ? nil : values.joined(separator: ", ") }

    init(_ values: [String]) { self.values = values }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            values = [string]
        } else if let strings = try? container.decode([String].self) {
            values = strings
        } else if let number = try? container.decode(Double.self) {
            values = [number == number.rounded() ? String(Int64(number)) : String(number)]
        } else if let bool = try? container.decode(Bool.self) {
            values = [String(bool)]
        } else {
            values = []
        }
    }
}

/// `GET /advancedsearch.php?output=json` response.
struct SearchResponse: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        var numFound: Int?
        var docs: [SearchDoc]
    }

    var response: Body
}

struct SearchDoc: Decodable, Sendable {
    var identifier: String
    var title: FlexibleStrings?
    var creator: FlexibleStrings?
    var licenseurl: FlexibleStrings?
    var collection: FlexibleStrings?
}

/// `GET /metadata/<identifier>` response. A missing item comes back as `{}`, so every field is optional.
struct MetadataResponse: Decodable, Sendable {
    var metadata: ItemMetadata?
    var files: [FileEntry]?
    var isDark: Bool?

    enum CodingKeys: String, CodingKey {
        case metadata, files
        case isDark = "is_dark"
    }
}

struct ItemMetadata: Decodable, Sendable {
    var identifier: FlexibleStrings?
    var title: FlexibleStrings?
    var creator: FlexibleStrings?
    var licenseurl: FlexibleStrings?
    var collection: FlexibleStrings?
}

struct FileEntry: Decodable, Sendable {
    var name: String
    var source: FlexibleStrings?
    var format: FlexibleStrings?
    var size: FlexibleStrings?
    var md5: FlexibleStrings?
    var title: FlexibleStrings?
    var artist: FlexibleStrings?
    var creator: FlexibleStrings?
    var album: FlexibleStrings?
    var track: FlexibleStrings?
    var length: FlexibleStrings?
}
