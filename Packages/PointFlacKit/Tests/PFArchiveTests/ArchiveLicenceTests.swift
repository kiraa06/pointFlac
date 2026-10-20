import Foundation
import Testing

@testable import PFArchive

@Suite("Archive licences and queries")
struct ArchiveLicenceTests {
    @Test(
        "Creative Commons and public-domain deeds are recognised and named",
        arguments: [
            ("http://creativecommons.org/licenses/by-nc-nd/3.0/", "CC BY-NC-ND 3.0"),
            ("https://creativecommons.org/licenses/by-nc-sa/4.0/", "CC BY-NC-SA 4.0"),
            ("http://creativecommons.org/licenses/by-nc-sa/3.0/us/", "CC BY-NC-SA 3.0 US"),
            ("https://www.creativecommons.org/licenses/by/4.0", "CC BY 4.0"),
            ("https://creativecommons.org/publicdomain/zero/1.0/", "CC0 1.0"),
            ("http://creativecommons.org/publicdomain/mark/1.0/", "Public Domain Mark 1.0"),
            ("http://creativecommons.org/licenses/publicdomain/", "Public domain"),
        ])
    func recognises(url: String, name: String) {
        #expect(ArchiveLicence.classify(licenseURL: url, collections: [])?.name == name)
    }

    @Test(
        "anything else hides the item",
        arguments: [
            "http://rightsstatements.org/vocab/InC/1.0/", "https://creativecommons.org.evil.example/licenses/by/4.0/",
            "ftp://creativecommons.org/licenses/by/4.0/", "https://creativecommons.org/", "All rights reserved", "",
            "https://creativecommons.org/licenses/<script>/1.0/",
        ])
    func refuses(url: String) {
        #expect(ArchiveLicence.classify(licenseURL: url, collections: ["opensource_audio"]) == nil)
    }

    @Test("an item with no licence is hidden unless it belongs to the Live Music Archive")
    func etree() {
        #expect(ArchiveLicence.classify(licenseURL: nil, collections: []) == nil)
        #expect(ArchiveLicence.classify(licenseURL: nil, collections: ["GratefulDead", "etree"]) == .etree)
        let both = ArchiveLicence.classify(
            licenseURL: "https://creativecommons.org/licenses/by/4.0/", collections: ["etree"])
        #expect(both?.name == "CC BY 4.0", "an explicit licence wins over the collection")
    }

    @Test("user text cannot widen the query or escape the licence filter")
    func queryEscaping() throws {
        let query = try #require(ArchiveQuery.build(#"AC/DC) OR (collection:commercial* AND NOT "x\ dusty-sense"#))
        #expect(query.hasSuffix(ArchiveQuery.filters))
        let userPart = String(query.dropLast(ArchiveQuery.filters.count))
        #expect(
            userPart
                == #"("AC" "DC" "OR" "collection" "commercial" "AND" "NOT" "x" "dusty-sense") AND "#)
        #expect(ArchiveQuery.build("   ") == nil)
        #expect(ArchiveQuery.build("()*:") == nil)
        #expect(ArchiveQuery.words("Señor Coconut") == ["Señor", "Coconut"])
    }

    @Test("search URLs carry the query, fields, sort and page size")
    func searchURL() throws {
        let url = try #require(
            ArchiveQuery.searchURL(base: URL(string: "https://archive.org")!, query: "a+b c", rows: 20))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path() == "/advancedsearch.php")
        #expect(items.first { $0.name == "q" }?.value == "a+b c")
        #expect(items.filter { $0.name == "fl[]" }.compactMap(\.value) == ArchiveQuery.fields)
        #expect(items.first { $0.name == "rows" }?.value == "20")
        #expect(items.first { $0.name == "sort[]" }?.value == "downloads desc")
        #expect(items.first { $0.name == "output" }?.value == "json")
        #expect(url.absoluteString.contains("a%2Bb"))
    }

    @Test("download URLs encode each path segment and refuse hostile identifiers or paths")
    func downloadURLs() {
        let base = URL(string: "https://archive.org")!
        #expect(
            ArchiveQuery.downloadURL(base: base, identifier: "dusty-sense", path: "disc 1/Señor #1?.flac")?
                .absoluteString
                == "https://archive.org/download/dusty-sense/disc%201/Se%C3%B1or%20%231%3F.flac")
        #expect(ArchiveQuery.downloadURL(base: base, identifier: "../etc", path: "a.flac") == nil)
        #expect(ArchiveQuery.downloadURL(base: base, identifier: "ok", path: "../a.flac") == nil)
        #expect(ArchiveQuery.downloadURL(base: base, identifier: "ok", path: "/abs.flac") == nil)
        #expect(ArchiveQuery.downloadURL(base: base, identifier: "ok", path: "a//b.flac") == nil)
        #expect(ArchiveQuery.metadataURL(base: base, identifier: "id with space") == nil)
    }
}
