import Testing

@testable import PFAudio

/// One render call into a stereo buffer of `frames` frames; returns the real frames.
private func render(_ source: RenderSource, frames: Int) -> Int {
    var buffer = [UInt32](repeating: 0xAAAA_AAAA, count: frames * 2)
    return buffer.withUnsafeMutableBytes { source.render(into: $0.baseAddress!, frames: frames) }
}

private func write(_ source: RenderSource, frames: Int) {
    let words = [UInt32](repeating: 0x3F00_0000, count: frames * 2)
    #expect(words.withUnsafeBufferPointer { source.write($0) } == words.count)
}

/// Final review (minor): underruns were uncounted. `underrunFrames` counts the frames of silence `render` had to fill
/// because the ring ran dry mid-stream, and nothing deliberate: not the start-up before the first real frame, not a
/// flush or a seek hold, not the end of the stream once the producer has said so.
@Suite struct RenderSourceTests {
    @Test func countsUnderrunsOnlyMidStream() {
        let source = RenderSource(channels: 2, capacityFrames: 64, renderedFrames: 0, inheritingHoldsFrom: nil)
        // Start-up: nothing written yet, then a first callback that is only partly real.
        #expect(render(source, frames: 16) == 0)
        write(source, frames: 10)
        #expect(render(source, frames: 16) == 10)
        #expect(source.underrunFrames == 0)

        // Mid-stream: the ring runs dry, wholly and then partly.
        #expect(render(source, frames: 16) == 0)
        #expect(source.underrunFrames == 16)
        write(source, frames: 4)
        #expect(render(source, frames: 16) == 4)
        #expect(source.underrunFrames == 28)

        // A seek hold and a flush are silence on purpose.
        write(source, frames: 8)
        source.holdForSeek()
        #expect(render(source, frames: 16) == 0)
        let flush = source.requestFlush()
        #expect(render(source, frames: 16) == 0)
        #expect(source.isFlushAcknowledged(flush))
        source.releaseSeekHolds(through: source.seekHoldTicket)
        #expect(source.underrunFrames == 28)

        // The end of the stream: the producer said nothing more is coming.
        write(source, frames: 2)
        source.markEndOfStream()
        #expect(render(source, frames: 16) == 2)
        #expect(render(source, frames: 16) == 0)
        #expect(source.underrunFrames == 28)
        // Writing again (a seek after the end) resumes counting.
        write(source, frames: 2)
        #expect(render(source, frames: 16) == 2)
        #expect(source.underrunFrames == 28 + 14)
        // The 8 frames the flush dropped were never rendered.
        #expect(source.renderedFrames == 10 + 4 + 2 + 2)

        // A replacement source carries the count on, like `renderedFrames`.
        let next = RenderSource(channels: 2, capacityFrames: 64, renderedFrames: 18, inheritingHoldsFrom: source)
        #expect(next.underrunFrames == 42)
        #expect(render(next, frames: 8) == 0)
        #expect(next.underrunFrames == 42, "the replacement's start-up counted")
    }
}
