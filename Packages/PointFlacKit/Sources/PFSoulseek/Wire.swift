import Foundation

/// Why a message could not be read. Every parser in this module throws one of these instead of trapping, because every
/// byte it reads comes from an unauthenticated server or peer (spec §5.6).
public enum WireError: Error, Sendable, Equatable {
    case truncated
    case stringTooLong(Int)
    case countTooLarge(Int)
    case frameTooLarge(Int)
    case malformed(String)
    case inflateFailed
    case inflatedTooLarge(Int)
}

/// Limits applied while reading. They exist so a hostile peer cannot make the app allocate large buffers from a single
/// length field: each limit is checked before anything is allocated.
struct WireLimits: Sendable {
    /// No legitimate Soulseek string (a path, a username, a reason) comes near this.
    var maxString = 64 * 1024
    /// Files in one search response, attributes per file, phrases in a list.
    var maxCount = 100_000
}

/// Appends Soulseek's little-endian wire types. Strings are a u32 byte count followed by UTF-8 bytes.
struct WireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }

    mutating func bool(_ value: Bool) { bytes.append(value ? 1 : 0) }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        u32(UInt32(clamping: utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func raw(_ value: [UInt8]) { bytes.append(contentsOf: value) }

    /// A server or peer message: u32 length, u32 code, payload. The length counts the code and the payload.
    static func message(code: UInt32, _ build: (inout WireWriter) -> Void = { _ in }) -> [UInt8] {
        var body = WireWriter()
        body.u32(code)
        build(&body)
        var frame = WireWriter()
        frame.u32(UInt32(body.bytes.count))
        frame.raw(body.bytes)
        return frame.bytes
    }

    /// A peer-init message (the first message on a peer connection): u32 length, u8 code, payload.
    static func initMessage(code: UInt8, _ build: (inout WireWriter) -> Void) -> [UInt8] {
        var body = WireWriter()
        body.u8(code)
        build(&body)
        var frame = WireWriter()
        frame.u32(UInt32(body.bytes.count))
        frame.raw(body.bytes)
        return frame.bytes
    }
}

/// A strict reader over one message payload. Every accessor checks bounds and throws `WireError` on short input, so
/// garbage from the network can never crash the app.
struct WireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    let limits: WireLimits

    init(_ bytes: [UInt8], limits: WireLimits = WireLimits()) {
        self.bytes = bytes
        self.limits = limits
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    private mutating func take(_ count: Int) throws(WireError) -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else { throw .truncated }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func u8() throws(WireError) -> UInt8 { try take(1).first! }

    mutating func bool() throws(WireError) -> Bool { try u8() != 0 }

    mutating func u16() throws(WireError) -> UInt16 {
        let slice = try take(2)
        return slice.reversed().reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    mutating func u32() throws(WireError) -> UInt32 {
        let slice = try take(4)
        return slice.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func u64() throws(WireError) -> UInt64 {
        let slice = try take(8)
        return slice.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// A u32 count, checked against `limits.maxCount` so a hostile count cannot drive a huge loop or allocation.
    mutating func count() throws(WireError) -> Int {
        let value = Int(try u32())
        guard value <= limits.maxCount else { throw .countTooLarge(value) }
        return value
    }

    /// Strings decode leniently (invalid UTF-8 becomes U+FFFD) because some old clients send Latin-1 paths.
    mutating func string() throws(WireError) -> String {
        let length = Int(try u32())
        guard length <= limits.maxString else { throw .stringTooLong(length) }
        return String(decoding: try take(length), as: UTF8.self)
    }

    /// Soulseek sends IPv4 addresses as a little-endian u32, so the octets arrive reversed.
    mutating func ipv4() throws(WireError) -> String {
        let slice = Array(try take(4))
        return "\(slice[3]).\(slice[2]).\(slice[1]).\(slice[0])"
    }

    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[min(offset, bytes.count)...])
    }
}
