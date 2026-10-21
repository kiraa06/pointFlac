import Testing

@testable import PFCore

@Suite struct LumaTests {
    @Test func weightsFollowRec709() {
        #expect(abs(Luma.grey(r: 1, g: 0, b: 0) - 0.2126) < 1e-9)
        #expect(abs(Luma.grey(r: 0, g: 1, b: 0) - 0.7152) < 1e-9)
        #expect(abs(Luma.grey(r: 0, g: 0, b: 1) - 0.0722) < 1e-9)
    }

    @Test func whiteAndBlackStay() {
        #expect(abs(Luma.grey(r: 1, g: 1, b: 1) - 1) < 1e-9)
        #expect(Luma.grey(r: 0, g: 0, b: 0) == 0)
    }

    @Test func greysMapToThemselves() {
        #expect(abs(Luma.grey(r: 0.4, g: 0.4, b: 0.4) - 0.4) < 1e-9)
    }

    @Test func contrastExtremes() {
        #expect(abs(Luma.contrast(0, 1) - 21) < 1e-6)
        #expect(abs(Luma.contrast(0.5, 0.5) - 1) < 1e-9)
    }

    @Test func readableDarkensOnLightAndLightensOnDark() {
        let onLight = Luma.readable(0.5, on: 0.95)
        #expect(onLight < 0.5 && Luma.contrast(onLight, 0.95) >= 4.5)
        let onDark = Luma.readable(0.3, on: 0.07)
        #expect(onDark > 0.3 && Luma.contrast(onDark, 0.07) >= 4.5)
        #expect(Luma.readable(0.1, on: 0.95) == 0.1)
    }

    @Test func readableMeasuresTranslucentGreyAsComposited() {
        // Black at 40% over a light page is a mid grey: too faint at 4.5:1 until it is pushed darker (here, to 0).
        let g = Luma.readable(0.0, alpha: 0.4, on: 0.95)
        #expect(g == 0)
        // White at 50% over a dark page needs to get lighter or stay; the composite must clear the ratio or max out.
        let w = Luma.readable(0.6, alpha: 0.5, on: 0.07)
        let composite = w * 0.5 + 0.07 * 0.5
        #expect(Luma.contrast(composite, 0.07) >= 4.5 || w == 1)
        #expect(w >= 0.6)
    }
}
