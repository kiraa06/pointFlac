import Foundation
import PFTestSupport
import Testing

@Test func manifestLoadsAndRawMatchesFrames() throws {
    #expect(Fixtures.all.count == 24)
    let f = Fixtures.named("s32-96000")
    #expect(f.bits == 32 && f.sampleRate == 96_000 && f.expect == .accept)
    #expect(Int64(Fixtures.rawSamples(f).count) == f.frames * Int64(f.channels))
    #expect(FileManager.default.fileExists(atPath: Fixtures.url(Fixtures.named("empty")).path))
}
