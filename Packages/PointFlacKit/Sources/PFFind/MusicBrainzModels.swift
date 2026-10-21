import Foundation

/// The parts of MusicBrainz web-service JSON (`/ws/2/`, `fmt=json`) that the smart search reads. Everything is
/// optional except identifiers and names, because search results omit fields freely.
public enum MB {
    /// The searchable entity types this middleware uses.
    public enum Entity: String, Sendable, CaseIterable {
        case artist
        case releaseGroup = "release-group"
        case recording
        case release
    }

    public struct Alias: Decodable, Sendable, Hashable {
        public var name: String
        public var sortName: String?

        enum CodingKeys: String, CodingKey {
            case name
            case sortName = "sort-name"
        }
    }

    public struct ArtistRef: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var sortName: String?
        public var disambiguation: String?
        public var aliases: [Alias]?

        enum CodingKeys: String, CodingKey {
            case id, name, disambiguation, aliases
            case sortName = "sort-name"
        }
    }

    public struct ArtistCredit: Decodable, Sendable, Hashable {
        public var name: String
        public var joinphrase: String?
        public var artist: ArtistRef
    }

    public struct Artist: Decodable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var sortName: String?
        public var score: Int?
        public var type: String?
        public var country: String?
        public var disambiguation: String?
        public var aliases: [Alias]?

        enum CodingKeys: String, CodingKey {
            case id, name, score, type, country, disambiguation, aliases
            case sortName = "sort-name"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            sortName = try container.decodeIfPresent(String.self, forKey: .sortName)
            score = container.lenientInt(.score)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            country = try container.decodeIfPresent(String.self, forKey: .country)
            disambiguation = try container.decodeIfPresent(String.self, forKey: .disambiguation)
            aliases = try container.decodeIfPresent([Alias].self, forKey: .aliases)
        }
    }

    public struct ReleaseGroupRef: Decodable, Sendable, Hashable {
        public var id: String
        public var title: String?
        public var primaryType: String?
        public var secondaryTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case id, title
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
        }
    }

    public struct ReleaseGroup: Decodable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var score: Int?
        public var primaryType: String?
        public var secondaryTypes: [String]?
        public var firstReleaseDate: String?
        public var artistCredit: [ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case id, title, score
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
            case firstReleaseDate = "first-release-date"
            case artistCredit = "artist-credit"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            score = container.lenientInt(.score)
            primaryType = try container.decodeIfPresent(String.self, forKey: .primaryType)
            secondaryTypes = try container.decodeIfPresent([String].self, forKey: .secondaryTypes)
            firstReleaseDate = try container.decodeIfPresent(String.self, forKey: .firstReleaseDate)
            artistCredit = try container.decodeIfPresent([ArtistCredit].self, forKey: .artistCredit)
        }
    }

    public struct Medium: Decodable, Sendable, Hashable {
        public var format: String?
        public var trackCount: Int?

        enum CodingKeys: String, CodingKey {
            case format
            case trackCount = "track-count"
        }
    }

    public struct Release: Decodable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var score: Int?
        public var status: String?
        public var date: String?
        public var trackCount: Int?
        public var media: [Medium]?
        public var releaseGroup: ReleaseGroupRef?

        enum CodingKeys: String, CodingKey {
            case id, title, score, status, date, media
            case trackCount = "track-count"
            case releaseGroup = "release-group"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            score = container.lenientInt(.score)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            date = try container.decodeIfPresent(String.self, forKey: .date)
            trackCount = container.lenientInt(.trackCount)
            media = try container.decodeIfPresent([Medium].self, forKey: .media)
            releaseGroup = try container.decodeIfPresent(ReleaseGroupRef.self, forKey: .releaseGroup)
        }
    }

    public struct Recording: Decodable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var score: Int?
        public var length: Int?
        public var disambiguation: String?
        public var firstReleaseDate: String?
        public var artistCredit: [ArtistCredit]?
        public var releases: [Release]?

        enum CodingKeys: String, CodingKey {
            case id, title, score, length, disambiguation, releases
            case firstReleaseDate = "first-release-date"
            case artistCredit = "artist-credit"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            score = container.lenientInt(.score)
            length = container.lenientInt(.length)
            disambiguation = try container.decodeIfPresent(String.self, forKey: .disambiguation)
            firstReleaseDate = try container.decodeIfPresent(String.self, forKey: .firstReleaseDate)
            artistCredit = try container.decodeIfPresent([ArtistCredit].self, forKey: .artistCredit)
            releases = try container.decodeIfPresent([Release].self, forKey: .releases)
        }
    }

    /// A search response. Only the array for the searched entity is present.
    public struct SearchResponse: Decodable, Sendable {
        public var count: Int?
        public var artists: [Artist]?
        public var releaseGroups: [ReleaseGroup]?
        public var recordings: [Recording]?
        public var releases: [Release]?

        enum CodingKeys: String, CodingKey {
            case count, artists, recordings, releases
            case releaseGroups = "release-groups"
        }
    }
}

extension MB.ArtistCredit {
    /// "Gorillaz featuring De La Soul" from the credit list and its join phrases.
    static func displayName(_ credits: [MB.ArtistCredit]) -> String {
        credits.map { $0.name + ($0.joinphrase ?? "") }.joined().trimmingCharacters(in: .whitespaces)
    }
}

extension KeyedDecodingContainer {
    /// MusicBrainz has served `score` both as a number and as a string; accept either, and nothing on junk.
    fileprivate func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }
}

/// The year at the start of a MusicBrainz partial date ("2026-02-27", "2001").
func musicBrainzYear(_ date: String?) -> Int? {
    guard let date, date.count >= 4 else { return nil }
    return Int(date.prefix(4))
}
