import Foundation
import Testing

@testable import PFDesign

@Suite("Deck designs")
struct DeckDesignTests {
    @Test("the catalogue ships eight designs with unique IDs, the original first")
    func catalogue() {
        let ids = DeckDesign.catalogue.map(\.id)
        #expect(ids.count == 8)
        #expect(Set(ids).count == ids.count)
        #expect(DeckDesign.standard.id == "glasshouse")
        #expect(DeckDesign.standard.plinth == .frostedGlass)
    }

    @Test("an unknown ID falls back to the default design")
    func fallback() {
        #expect(DeckDesign.design(id: "studioSilver").name == "Studio Silver")
        #expect(DeckDesign.design(id: "removed-in-a-later-version") == DeckDesign.standard)
    }

    @Test("names carry no brand words")
    func noBrands() {
        let banned = ["technics", "beogram", "bang", "braun", "rega", "linn", "thorens", "dual", "pro-ject", "crosley"]
        for design in DeckDesign.catalogue {
            let text = "\(design.name) \(design.tagline) \(design.blurb)".lowercased()
            for word in banned { #expect(!text.contains(word), "\(design.id) mentions \(word)") }
        }
    }

    @Test("only the linear design uses a linear arm, and black vinyl is the default record")
    func armsAndRecords() {
        #expect(DeckDesign.catalogue.filter { $0.armStyle == .linear }.map(\.id) == ["linear"])
        #expect(RecordStyle.standard == .black)
    }

    @Test("strobe rows are the dot counts that stand still: 2 × mains × 60 / rpm")
    func strobe() {
        for row in VinylGeometry.strobeRows {
            let exact = 2.0 * Double(row.mainsHz) * 60.0 / row.rpm
            #expect(abs(Double(row.dots) - exact) < 0.5)
        }
    }

    @Test("a real LP's proportions: the platter is wider than the record, the label about a third of it")
    func proportions() {
        #expect(VinylGeometry.platterToRecord > 1.09 && VinylGeometry.platterToRecord < 1.11)
        #expect(abs(VinylGeometry.labelToRecord - 0.331) < 0.001)
        #expect(VinylGeometry.innerGrooveToRecord > VinylGeometry.labelToRecord)
        #expect(VinylGeometry.outerGrooveToRecord < 1)
    }
}
