import Compression
import Foundation

/// zlib (RFC 1950) inflate with a hard output cap.
///
/// Search responses and folder listings arrive zlib-compressed. A few kilobytes of hostile DEFLATE can expand to
/// gigabytes, so inflation streams into a buffer and stops the moment the output passes `limit` (spec §5.6 keeps the
/// fork's 16 MiB / 32 MiB caps). The Adler-32 trailer is checked because Apple's raw-DEFLATE decoder cannot report a
/// truncated stream on its own.
enum Inflate {
    /// Cap for a search response (peer code 9).
    static let searchResponseLimit = 16 * 1024 * 1024
    /// Cap for a folder listing (peer code 37).
    static let folderListingLimit = 32 * 1024 * 1024

    /// The first `count` inflated bytes (or fewer if the stream is shorter), without the checksum. Used to read a
    /// search response's token before deciding whether the whole response is worth inflating.
    static func zlibPrefix(_ input: [UInt8], count: Int) throws(WireError) -> [UInt8] {
        try checkHeader(input)
        return try rawDeflate(Array(input[2..<(input.count - 4)]), limit: Int.max, stopAfter: count)
    }

    private static func checkHeader(_ input: [UInt8]) throws(WireError) {
        guard input.count >= 6 else { throw .inflateFailed }
        let cmf = input[0]
        let flg = input[1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0, flg & 0x20 == 0 else {
            throw .inflateFailed
        }
    }

    static func zlib(_ input: [UInt8], limit: Int) throws(WireError) -> [UInt8] {
        try checkHeader(input)
        let deflate = Array(input[2..<(input.count - 4)])
        let output = try rawDeflate(deflate, limit: limit)
        let trailer = input.suffix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard adler32(output) == trailer else { throw .inflateFailed }
        return output
    }

    private static func rawDeflate(_ input: [UInt8], limit: Int, stopAfter: Int? = nil) throws(WireError) -> [UInt8] {
        let chunk = 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard
            compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw .inflateFailed }
        defer { compression_stream_destroy(streamPointer) }

        enum Outcome {
            case finished(compression_status)
            case prefix
            case tooLarge
            case noInput
        }
        var output: [UInt8] = []
        let outcome: Outcome = input.withUnsafeBufferPointer { source -> Outcome in
            guard let base = source.baseAddress else { return .noInput }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = source.count
            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = chunk
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - streamPointer.pointee.dst_size
                if output.count + produced > limit { return .tooLarge }
                output.append(contentsOf: UnsafeBufferPointer(start: destination, count: produced))
                if let stopAfter, output.count >= stopAfter { return .prefix }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // With FINALIZE set, OK and no output means the decoder wants input that is not there: the stream
                    // is truncated or corrupt. Bail out rather than spin.
                    if produced == 0 { return .finished(COMPRESSION_STATUS_ERROR) }
                    continue
                default:
                    return .finished(status)
                }
            }
        }
        switch outcome {
        case .tooLarge: throw .inflatedTooLarge(limit)
        case .prefix: return Array(output.prefix(stopAfter ?? output.count))
        case .noInput: throw .inflateFailed
        case .finished(let status):
            guard status == COMPRESSION_STATUS_END else { throw .inflateFailed }
            if let stopAfter { return Array(output.prefix(stopAfter)) }
            return output
        }
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
        return (b << 16) | a
    }
}
