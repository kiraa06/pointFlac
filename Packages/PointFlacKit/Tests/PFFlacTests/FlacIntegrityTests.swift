import Foundation
import PFTestSupport
import Testing

@testable import PFFlac

private func verify(_ name: String) throws -> FlacIntegrityResult {
    try FlacIntegrity.verify(fileAt: Fixtures.url(Fixtures.named(name)))
}

@Suite struct FlacIntegrityTests {
    @Test func integrityResults() throws {
        #expect(try verify("s16-44100") == .intact)
        #expect(try verify("nomd5-s16-44100") == .noSignature)
        #expect(try verify("corrupt-mid-s16-44100") == .damaged)
    }

    @Test(arguments: Fixtures.all.filter { $0.expect == .accept && $0.hasMD5 && $0.name != "corrupt-mid-s16-44100" })
    func everyIntactFixtureVerifies(_ f: Fixture) throws {
        #expect(try FlacIntegrity.verify(fileAt: Fixtures.url(f)) == .intact)
    }

    @Test func signatureMismatchWithoutFrameErrorsIsDamaged() throws {
        // Every frame CRC still passes; only the STREAMINFO MD5 (bytes 26..<42 after "fLaC" and the block header)
        // no longer matches the audio.
        var bytes = try Data(contentsOf: Fixtures.url(Fixtures.named("s16-44100")))
        bytes[26] ^= 0x01
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID()).flac")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FlacIntegrity.verify(fileAt: url) == .damaged)
    }

    @Test func unopenableFileThrows() {
        #expect(throws: FlacDecodeError.openFailed) { try verify("renamed-mp3") }
    }
}
