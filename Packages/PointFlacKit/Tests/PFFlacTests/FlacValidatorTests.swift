import Foundation
import PFCore
import PFTestSupport
import Testing

@testable import PFFlac

extension Fixture: CustomTestStringConvertible {
    public var testDescription: String { name }
}

private func caseName(_ error: FlacRejection) -> String {
    let full = String(describing: error)
    return String(full.prefix { $0 != "(" })
}

@Test(arguments: Fixtures.all) func admitsExactlyTheRightFixtures(_ f: Fixture) {
    let result = Result { () throws(FlacRejection) -> FlacStreamInfo in
        try FlacValidator.validate(fileAt: Fixtures.url(f))
    }
    switch result {
    case .success(let info):
        #expect(f.expect == .accept)
        #expect(info.sampleRate == f.sampleRate && info.bitsPerSample == f.bits && info.channels == f.channels)
        #expect(info.totalFrames == f.frames && info.hasMD5 == f.hasMD5)
        #expect(info.format == AudioFormat(sampleRate: f.sampleRate, bitsPerSample: f.bits, channels: f.channels))
    case .failure(let error):
        #expect(f.expect == .reject)
        #expect(caseName(error) == f.rejection)
    }
}

private struct CountingReader: FlacByteReader {
    let data: Data
    let name: String
    var position = 0
    var bytesRead = 0
    var size: Int { data.count }

    mutating func read(_ count: Int) throws(FlacRejection) -> [UInt8] {
        let end = min(position + count, data.count)
        let out = [UInt8](data[position..<end])
        position = end
        bytesRead += out.count
        return out
    }

    mutating func skip(_ count: Int) throws(FlacRejection) {
        position += count
    }
}

/// 34-byte STREAMINFO body: blocks 4096/4096, no frame sizes, 44100 Hz, 2 ch, 16 bit, 0 samples, zero MD5.
private let streamInfoBody: [UInt8] =
    [0x10, 0x00, 0x10, 0x00, 0, 0, 0, 0, 0, 0] + [0x0A, 0xC4, 0x42, 0xF0, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 16)

@Test func readsAtMostFirstMegabyteForSmallFiles() throws {
    let f = Fixtures.named("s24-96000")
    var reader = CountingReader(data: try Data(contentsOf: Fixtures.url(f)), name: f.file)
    _ = try FlacValidator.validate(reader: &reader)
    #expect(reader.bytesRead > 0)
    #expect(reader.bytesRead < 1_048_576)
}

@Test func largeMetadataBlocksAreSkippedNotRead() throws {
    // fLaC, STREAMINFO (not last), then a 8 MiB PICTURE block (last) that is never read, then a frame header.
    var bytes: [UInt8] = Array("fLaC".utf8) + [0x00, 0, 0, 34]
    bytes += streamInfoBody
    let pictureLength = 8 * 1024 * 1024
    bytes += [0x86, UInt8(pictureLength >> 16), UInt8((pictureLength >> 8) & 0xFF), UInt8(pictureLength & 0xFF)]
    var header: [UInt8] = [0xFF, 0xF8, 0x69, 0x18, 0x00, 0x0F]  // block size code 6 carries one extension byte
    var crc: UInt8 = 0
    for b in header {
        crc ^= b
        for _ in 0..<8 { crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
    }
    header.append(crc)
    var data = Data(bytes)
    data.append(Data(repeating: 0, count: pictureLength))
    data.append(contentsOf: header)
    var reader = CountingReader(data: data, name: "big.flac")
    let info = try FlacValidator.validate(reader: &reader)
    #expect(info.sampleRate == 44_100)
    #expect(reader.bytesRead < 1_000)
}

@Test func rejectsMoreThanMaxBlocks() {
    var bytes: [UInt8] = Array("fLaC".utf8) + [0x00, 0, 0, 34]
    bytes += streamInfoBody
    for _ in 0..<FlacValidator.maxBlocks { bytes += [0x01, 0, 0, 0] }  // padding blocks, never last
    var reader = CountingReader(data: Data(bytes), name: "many.flac")
    #expect(throws: FlacRejection.tooManyBlocks) { try FlacValidator.validate(reader: &reader) }
}
