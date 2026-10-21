import Testing

@testable import PFFind

@Suite struct FindTextTests {
    @Test func foldsDiacriticsCaseAndPunctuation() {
        #expect(FindText.fold("Björk") == "bjork")
        #expect(FindText.fold("Sigur Rós – Ágætis byrjun") == "sigur ros agaetis byrjun")
        #expect(FindText.fold("Mötley Crüe") == "motley crue")
        #expect(FindText.fold("Røyksopp") == "royksopp")
        #expect(FindText.fold("AC/DC") == "ac dc")
        #expect(FindText.fold("  Feel   Good Inc. ") == "feel good inc")
        #expect(FindText.fold("ＷＩＤＥ") == "wide")
    }

    @Test func spellsAmpersandAsAnd() {
        #expect(FindText.fold("Simon & Garfunkel") == FindText.fold("Simon and Garfunkel"))
        #expect(FindText.fold("Rock&Roll") == "rock and roll")
    }

    @Test func dropsApostrophesSoContractionsAgree() {
        #expect(FindText.fold("Don't Stop") == "dont stop")
        #expect(FindText.fold("Don’t Stop") == "dont stop")
    }

    @Test func stripsLeadingArticle() {
        #expect(FindText.withoutLeadingArticle("The Beatles") == "Beatles")
        #expect(FindText.withoutLeadingArticle("The The") == "The The")
        #expect(FindText.withoutLeadingArticle("Theatre of Tragedy") == "Theatre of Tragedy")
    }

    @Test(arguments: [
        ("Feel Good Inc. (feat. De La Soul)", "Feel Good Inc."),
        ("Clint Eastwood [ft. Del the Funky Homosapien]", "Clint Eastwood"),
        ("Stylo featuring Mos Def & Bobby Womack", "Stylo"),
        ("Empire Ants (with Little Dragon)", "Empire Ants"),
        ("Dancing with Myself", "Dancing with Myself"),
    ])
    func removesFeaturedCredits(input: String, expected: String) {
        #expect(FindText.withoutFeaturing(input) == expected)
    }

    @Test(arguments: [
        ("Abbey Road (Remastered 2009)", "Abbey Road"),
        ("Demon Days [Deluxe Edition]", "Demon Days"),
        ("Hey Jude - 2015 Remaster", "Hey Jude"),
        ("Song 2 - Live at Glastonbury", "Song 2"),
        ("Rock - Paper - Scissors", "Rock - Paper - Scissors"),
        ("(What's the Story) Morning Glory?", "Morning Glory?"),
    ])
    func removesEditionNoise(input: String, expected: String) {
        #expect(FindText.withoutParentheticals(input) == expected)
    }
}

@Suite struct FuzzyMatcherTests {
    @Test func exactBeatsPrefixBeatsTypoBeatsUnrelated() {
        let exact = FuzzyMatcher.score(query: "gorillaz", candidate: "Gorillaz")
        let prefix = FuzzyMatcher.score(query: "gorill", candidate: "Gorillaz", queryIsPartial: true)
        let typo = FuzzyMatcher.score(query: "gorilaz", candidate: "Gorillaz")
        let unrelated = FuzzyMatcher.score(query: "radiohead", candidate: "Gorillaz")
        #expect(exact > prefix)
        #expect(prefix > typo)
        #expect(typo > 0.6)
        #expect(unrelated < 0.2)
    }

    @Test func toleratesTranspositionsAndOneEdit() {
        #expect(FuzzyMatcher.editDistance("radiohed", "radiohead", limit: 1) == 1)
        #expect(FuzzyMatcher.editDistance("mountian", "mountain", limit: 1) == 1)
        #expect(FuzzyMatcher.editDistance("abc", "xyz", limit: 1) == nil)
        #expect(FuzzyMatcher.score(query: "mountian", candidate: "The Mountain") > 0.6)
    }

    @Test func ignoresDiacriticsTheAndAmpersand() {
        #expect(FuzzyMatcher.score(query: "bjork", candidate: "Björk") > 0.95)
        #expect(FuzzyMatcher.score(query: "beatles", candidate: "The Beatles") > 0.95)
        #expect(FuzzyMatcher.score(query: "simon and garfunkel", candidate: "Simon & Garfunkel") > 0.95)
        #expect(FuzzyMatcher.score(query: "acdc", candidate: "AC/DC") > 0.9)
    }

    @Test func extraCandidateWordsCostLittle() {
        let folder = FuzzyMatcher.score(query: "the mountain", candidate: "Gorillaz - The Mountain (2026) [FLAC]")
        #expect(folder > 0.8)
    }

    @Test func partialTypoWhileTyping() {
        #expect(FuzzyMatcher.score(query: "gorrill", candidate: "Gorillaz", queryIsPartial: true) > 0.6)
        #expect(FuzzyMatcher.score(query: "goirll", candidate: "Gorillaz", queryIsPartial: true) > 0.5)
        #expect(FuzzyMatcher.score(query: "gorrill", candidate: "Gorillaz", queryIsPartial: false) < 0.6)
    }
}
