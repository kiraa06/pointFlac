import Testing

@testable import PFDownloads

@Suite("RemoteTrack labels")
struct RemoteTrackTests {
    static func track(bits: Int?, rate: Int?, size: Int64? = nil) -> RemoteTrack {
        RemoteTrack(
            id: "x", provider: "archive", title: "T", fileName: "t.flac", sizeBytes: size, bitsPerSample: bits,
            sampleRate: rate)
    }

    @Test("format labels state only what the provider said")
    func formats() {
        #expect(Self.track(bits: 24, rate: 96_000).formatLabel == "FLAC 24/96")
        #expect(Self.track(bits: 16, rate: 44_100).formatLabel == "FLAC 16/44.1")
        #expect(Self.track(bits: 24, rate: nil).formatLabel == "FLAC 24-bit")
        #expect(Self.track(bits: nil, rate: 48_000).formatLabel == "FLAC 48 kHz")
        #expect(Self.track(bits: nil, rate: nil).formatLabel == "FLAC")
    }

    @Test("size labels are empty when the size is unknown")
    func sizes() {
        #expect(Self.track(bits: nil, rate: nil).sizeLabel.isEmpty)
        #expect(!Self.track(bits: nil, rate: nil, size: 3_553_564).sizeLabel.isEmpty)
    }
}
