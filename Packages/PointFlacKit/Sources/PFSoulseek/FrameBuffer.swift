import Foundation

/// One length-prefixed message taken off a connection.
struct Frame: Sendable, Equatable {
    var code: UInt32
    var payload: [UInt8]
}

/// Splits a byte stream into Soulseek frames (u32 length, then the body).
///
/// The cap is checked as soon as the 4-byte length arrives, before any of the body is buffered, so a peer that announces
/// 4 GiB is dropped after sending 4 bytes. The buffer therefore never holds more than one capped frame plus one receive
/// chunk (spec §5.6: "A peer must not be able to make the app buffer 4 GiB"). Lengths are widened to `Int` before any
/// arithmetic, which removes the `message_size + 4` overflow the fork's library had.
struct FrameBuffer: Sendable {
    enum CodeWidth: Sendable { case u8, u32 }

    let maxFrame: Int
    private(set) var buffer: [UInt8] = []
    private var start = 0

    init(maxFrame: Int) { self.maxFrame = maxFrame }

    var bufferedCount: Int { buffer.count - start }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        compactIfNeeded()
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, `nil` if more bytes are needed. Throws if the announced length breaks the cap or is too
    /// short to hold a code.
    mutating func next(codeWidth: CodeWidth = .u32) throws(WireError) -> Frame? {
        guard bufferedCount >= 4 else { return nil }
        let length = Int(littleEndianU32(at: start))
        let codeSize = codeWidth == .u8 ? 1 : 4
        guard length <= maxFrame else { throw .frameTooLarge(length) }
        guard length >= codeSize else { throw .malformed("frame shorter than its code") }
        guard bufferedCount >= 4 + length else { return nil }
        let bodyStart = start + 4
        let code: UInt32 = codeWidth == .u8 ? UInt32(buffer[bodyStart]) : littleEndianU32(at: bodyStart)
        let payload = Array(buffer[(bodyStart + codeSize)..<(bodyStart + length)])
        start = bodyStart + length
        return Frame(code: code, payload: payload)
    }

    /// Hands back whatever follows the frames read so far (file data on an F connection) and empties the buffer.
    mutating func drain() -> [UInt8] {
        defer {
            buffer.removeAll(keepingCapacity: false)
            start = 0
        }
        return Array(buffer[start...])
    }

    /// Takes exactly `count` raw bytes if they are buffered (the FileTransferInit token on an F connection).
    mutating func takeRaw(_ count: Int) -> [UInt8]? {
        guard bufferedCount >= count else { return nil }
        defer { start += count }
        return Array(buffer[start..<(start + count)])
    }

    private func littleEndianU32(at index: Int) -> UInt32 {
        UInt32(buffer[index]) | UInt32(buffer[index + 1]) << 8 | UInt32(buffer[index + 2]) << 16
            | UInt32(buffer[index + 3]) << 24
    }

    private mutating func compactIfNeeded() {
        if start > 0 && (start >= 64 * 1024 || start == buffer.count) {
            buffer.removeFirst(start)
            start = 0
        }
    }
}
