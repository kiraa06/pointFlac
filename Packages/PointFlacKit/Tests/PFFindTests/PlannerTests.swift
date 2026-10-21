import Testing

@testable import PFFind

@Suite struct SoulseekQueryPlannerTests {
    let mountain = ResolvedEntity(
        kind: .album, artist: "Gorillaz", album: "The Mountain", year: 2026, trackCount: 15)

    @Test func gorillazTheMountainLeadsWithTheAlbumTitle() {
        let plan = SoulseekQueryPlanner.plan(for: mountain)
        #expect(plan.variants.map(\.query) == ["the mountain", "gorillaz mountain"])
        #expect(plan.variants[0].intent == .albumOnly)
        #expect(plan.variants[0].requiresArtistFilter)
        #expect(plan.variants[1].intent == .artistAndAlbum)
        #expect(!plan.variants[1].requiresArtistFilter)
        #expect(plan.blockedByExcludedPhrase == nil)
    }

    @Test func dropsStopwordsWhenEnoughDistinctiveWordsRemain() {
        let entity = ResolvedEntity(kind: .album, artist: "Depeche Mode", album: "Songs of Faith and Devotion")
        let plan = SoulseekQueryPlanner.plan(for: entity)
        #expect(plan.variants.first?.query == "songs faith devotion")
        #expect(plan.variants.dropFirst().first?.query == "depeche mode songs faith devotion")
    }

    @Test func genericTitlesLeadWithTheArtist() {
        let entity = ResolvedEntity(kind: .album, artist: "The Beatles", album: "Live", year: 1977)
        let plan = SoulseekQueryPlanner.plan(for: entity)
        #expect(plan.variants.map(\.query) == ["beatles live", "beatles 1977"])
        #expect(plan.variants.allSatisfy { !$0.requiresArtistFilter })
    }

    @Test func stripsEditionNoisePunctuationAndKeepsNumbers() {
        let entity = ResolvedEntity(kind: .album, artist: "Prince", album: "1999 (Super Deluxe Edition)")
        #expect(SoulseekQueryPlanner.plan(for: entity).variants.first?.query == "prince 1999")
        let volume = ResolvedEntity(kind: .album, artist: "Kill Bill", album: "Kill Bill: Vol. 2")
        #expect(SoulseekQueryPlanner.plan(for: volume).variants.first?.query == "kill bill vol 2")
    }

    @Test func addsADiacriticFreeTwin() {
        let entity = ResolvedEntity(kind: .album, artist: "Björk", album: "Homogénic")
        let queries = SoulseekQueryPlanner.plan(for: entity).variants.map(\.query)
        #expect(queries == ["homogénic", "björk homogénic", "homogenic", "bjork homogenic"])
    }

    @Test func tracksDropFeaturedCreditsAndIncludeTheAlbum() {
        let entity = ResolvedEntity(
            kind: .track, artist: "Gorillaz", album: "Demon Days", track: "Feel Good Inc. (feat. De La Soul)")
        let plan = SoulseekQueryPlanner.plan(for: entity)
        #expect(plan.variants.map(\.query) == ["gorillaz feel good inc", "feel good inc", "demon days"])
        #expect(plan.variants[1].requiresArtistFilter)
        #expect(plan.variants[2].intent == .albumOnly)
    }

    @Test func apostrophesAndSingleLettersDoNotBecomeWords() {
        let entity = ResolvedEntity(kind: .track, artist: "Fleetwood Mac", track: "Don't Stop")
        #expect(SoulseekQueryPlanner.plan(for: entity).variants.first?.query == "fleetwood mac don stop")
    }

    @Test func neverEmitsAVariantContainingAnExcludedPhrase() {
        let entity = ResolvedEntity(kind: .album, artist: "Some Artist", album: "Blue Mountain Sessions")
        let plan = SoulseekQueryPlanner.plan(for: entity, excludedPhrases: ["Artist Blue"])
        // "some artist blue mountain sessions" contains "artist blue", so only the title variant survives.
        #expect(plan.variants.map(\.query) == ["blue mountain sessions"])
        let strict = SoulseekQueryPlanner.plan(for: entity, excludedPhrases: ["some artist"])
        // The excluded phrase is the entity's own artist: nothing is searched around it.
        #expect(strict.variants.isEmpty)
        #expect(strict.blockedByExcludedPhrase == "some artist")
        for variant in SoulseekQueryPlanner.plan(for: mountain, excludedPhrases: ["gorillaz mountain"]).variants {
            #expect(!variant.query.contains("gorillaz mountain"))
        }
    }

    @Test func excludedPhraseMatchingIgnoresCaseAndDiacritics() {
        let entity = ResolvedEntity(kind: .album, artist: "Björk", album: "Homogenic")
        let plan = SoulseekQueryPlanner.plan(for: entity, excludedPhrases: ["BJORK"])
        #expect(plan.variants.isEmpty)
        #expect(plan.blockedByExcludedPhrase == "bjork")
    }

    @Test func capsTheNumberOfVariants() {
        let entity = ResolvedEntity(kind: .album, artist: "Björk", album: "Homogénic")
        #expect(SoulseekQueryPlanner.plan(for: entity, maxVariants: 2).variants.count == 2)
    }

    @Test func artistEntities() {
        let entity = ResolvedEntity(kind: .artist, artist: "The Beatles")
        #expect(SoulseekQueryPlanner.plan(for: entity).variants.map(\.query) == ["beatles"])
    }
}

@Suite struct ArchiveQueryBuilderTests {
    @Test func albumQueriesGoFromPreciseToLoose() {
        let entity = ResolvedEntity(kind: .album, artist: "Gorillaz", album: "The Mountain (Deluxe)")
        let queries = ArchiveQueryBuilder.queries(for: entity)
        let flac = ArchiveQueryBuilder.flacClause
        #expect(
            queries == [
                #"creator:("Gorillaz") AND title:("The Mountain") AND "# + flac,
                "creator:(gorillaz) AND title:(mountain) AND " + flac,
                #"title:("The Mountain") AND "# + flac,
            ])
    }

    @Test func escapesQuotes() {
        let entity = ResolvedEntity(kind: .artist, artist: #"The "Band""#)
        #expect(ArchiveQueryBuilder.queries(for: entity).first?.hasPrefix(#"creator:("The \"Band\"")"#) == true)
    }

    @Test func trackQueriesIncludeTheAlbum() {
        let entity = ResolvedEntity(
            kind: .track, artist: "Grateful Dead", album: "Cornell 5/8/77", track: "Scarlet Begonias")
        let queries = ArchiveQueryBuilder.queries(for: entity)
        #expect(queries.count == 3)
        #expect(queries[1].contains(#"title:("Cornell 5/8/77")"#))
    }
}
