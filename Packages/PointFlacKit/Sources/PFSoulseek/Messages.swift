import CryptoKit
import Foundation

/// Server message codes this client sends or understands. Everything else from the server is read and ignored.
enum ServerCode {
    static let login: UInt32 = 1
    static let setWaitPort: UInt32 = 2
    static let getPeerAddress: UInt32 = 3
    static let connectToPeer: UInt32 = 18
    static let fileSearch: UInt32 = 26
    static let setStatus: UInt32 = 28
    static let serverPing: UInt32 = 32
    static let sharedFoldersFiles: UInt32 = 35
    static let relogged: UInt32 = 41
    static let haveNoParent: UInt32 = 71
    static let excludedSearchPhrases: UInt32 = 160
    static let cantConnectToPeer: UInt32 = 1001
}

/// Peer message codes. pointFlac only downloads, so the upload-side requests (browse, user info, folder contents,
/// QueueUpload from others) are deliberately not answered.
enum PeerCode {
    static let fileSearchResponse: UInt32 = 9
    static let transferRequest: UInt32 = 40
    static let transferResponse: UInt32 = 41
    static let queueUpload: UInt32 = 43
    static let placeInQueueResponse: UInt32 = 44
    static let uploadFailed: UInt32 = 46
    static let uploadDenied: UInt32 = 50
    static let placeInQueueRequest: UInt32 = 51
}

enum PeerInitCode {
    static let pierceFireWall: UInt8 = 0
    static let peerInit: UInt8 = 1
}

/// Frame caps (§5.6). Server control traffic is small; the largest legitimate server messages are room and privileged
/// user lists. Peer frames carry compressed search responses, which are far smaller than their inflated form.
enum FrameCaps {
    static let server = 4 * 1024 * 1024
    static let peer = 4 * 1024 * 1024
    static let peerInit = 4 * 1024
}

// MARK: - Outgoing

enum Outgoing {
    static func login(username: String, password: String, major: UInt32, minor: UInt32) -> [UInt8] {
        let digest = Insecure.MD5.hash(data: Data((username + password).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return WireWriter.message(code: ServerCode.login) {
            $0.string(username)
            $0.string(password)
            $0.u32(major)
            $0.string(hex)
            $0.u32(minor)
        }
    }

    static func setWaitPort(_ port: UInt32) -> [UInt8] {
        WireWriter.message(code: ServerCode.setWaitPort) { $0.u32(port) }
    }

    static func setStatusOnline() -> [UInt8] {
        WireWriter.message(code: ServerCode.setStatus) { $0.i32(2) }
    }

    /// Zero shared folders and files: pointFlac announces no shares (§5.6).
    static func sharedNothing() -> [UInt8] {
        WireWriter.message(code: ServerCode.sharedFoldersFiles) {
            $0.u32(0)
            $0.u32(0)
        }
    }

    /// We are a leaf of the distributed network and never ask for a parent to relay searches to us.
    static func haveNoParent() -> [UInt8] {
        WireWriter.message(code: ServerCode.haveNoParent) { $0.bool(true) }
    }

    static func ping() -> [UInt8] { WireWriter.message(code: ServerCode.serverPing) }

    static func fileSearch(token: UInt32, query: String) -> [UInt8] {
        WireWriter.message(code: ServerCode.fileSearch) {
            $0.u32(token)
            $0.string(query)
        }
    }

    static func getPeerAddress(_ username: String) -> [UInt8] {
        WireWriter.message(code: ServerCode.getPeerAddress) { $0.string(username) }
    }

    static func cantConnectToPeer(token: UInt32, username: String) -> [UInt8] {
        WireWriter.message(code: ServerCode.cantConnectToPeer) {
            $0.u32(token)
            $0.string(username)
        }
    }

    /// Answers a server-forwarded ConnectToPeer: u32 length 5, u8 code 0, u32 token.
    static func pierceFireWall(token: UInt32) -> [UInt8] {
        WireWriter.initMessage(code: PeerInitCode.pierceFireWall) { $0.u32(token) }
    }

    static func peerInit(username: String, type: String, token: UInt32 = 0) -> [UInt8] {
        WireWriter.initMessage(code: PeerInitCode.peerInit) {
            $0.string(username)
            $0.string(type)
            $0.u32(token)
        }
    }

    static func queueUpload(path: String) -> [UInt8] {
        WireWriter.message(code: PeerCode.queueUpload) { $0.string(path) }
    }

    static func placeInQueueRequest(path: String) -> [UInt8] {
        WireWriter.message(code: PeerCode.placeInQueueRequest) { $0.string(path) }
    }

    static func transferResponse(token: UInt32, allowed: Bool, reason: String? = nil) -> [UInt8] {
        WireWriter.message(code: PeerCode.transferResponse) {
            $0.u32(token)
            $0.bool(allowed)
            if !allowed { $0.string(reason ?? "Cancelled") }
        }
    }

    /// FileOffset: the first thing a downloader sends on an F connection, after the uploader's u32 token.
    static func fileOffset(_ offset: UInt64) -> [UInt8] {
        var writer = WireWriter()
        writer.u64(offset)
        return writer.bytes
    }
}

// MARK: - Incoming from the server

enum ServerMessage: Sendable, Equatable {
    case loginSucceeded(greeting: String)
    case loginFailed(reason: String)
    case peerAddress(username: String, ip: String, port: UInt32)
    case connectToPeer(ConnectRequest)
    case excludedPhrases([String])
    case relogged
    case cantConnectToPeer(token: UInt32)
    case other(code: UInt32)

    static func parse(_ frame: Frame) throws(WireError) -> ServerMessage {
        var reader = WireReader(frame.payload)
        switch frame.code {
        case ServerCode.login:
            if try reader.bool() {
                return .loginSucceeded(greeting: try reader.string())
            }
            return .loginFailed(reason: try reader.string())
        case ServerCode.getPeerAddress:
            let username = try reader.string()
            let ip = try reader.ipv4()
            let port = try reader.u32()
            return .peerAddress(username: username, ip: ip, port: port)
        case ServerCode.connectToPeer:
            let username = try reader.string()
            let type = try reader.string()
            let ip = try reader.ipv4()
            let port = try reader.u32()
            let token = try reader.u32()
            guard port > 0, port <= UInt32(UInt16.max) else { throw .malformed("ConnectToPeer port \(port)") }
            return .connectToPeer(
                ConnectRequest(username: username, type: type, ip: ip, port: UInt16(port), token: token))
        case ServerCode.excludedSearchPhrases:
            let count = try reader.count()
            var phrases: [String] = []
            phrases.reserveCapacity(min(count, 1024))
            for _ in 0..<count { phrases.append(try reader.string()) }
            return .excludedPhrases(phrases)
        case ServerCode.relogged:
            return .relogged
        case ServerCode.cantConnectToPeer:
            return .cantConnectToPeer(token: try reader.u32())
        default:
            return .other(code: frame.code)
        }
    }
}

/// A server-forwarded request for us to connect to a peer (ConnectToPeer, code 18).
struct ConnectRequest: Sendable, Equatable {
    var username: String
    /// "P" for peer messages, "F" for a file transfer, "D" for the distributed network (ignored).
    var type: String
    var ip: String
    var port: UInt16
    var token: UInt32
}

// MARK: - Incoming from peers

enum PeerMessage: Sendable, Equatable {
    case searchResponse(SearchResponse)
    /// The peer wants to upload `path` to us (direction 1) under `token`.
    case transferRequest(direction: UInt32, token: UInt32, path: String, size: Int64?)
    case placeInQueue(path: String, place: Int)
    case uploadFailed(path: String)
    case uploadDenied(path: String, reason: String)
    case other(code: UInt32)

    static func parse(_ frame: Frame) throws(WireError) -> PeerMessage {
        var reader = WireReader(frame.payload)
        switch frame.code {
        case PeerCode.fileSearchResponse:
            let inflated = try Inflate.zlib(frame.payload, limit: Inflate.searchResponseLimit)
            return .searchResponse(try SearchResponse.parse(inflated))
        case PeerCode.transferRequest:
            let direction = try reader.u32()
            let token = try reader.u32()
            let path = try reader.string()
            var size: Int64?
            if direction == 1 {
                let raw = try reader.u64()
                guard raw <= UInt64(Int64.max) else { throw .malformed("transfer size") }
                size = Int64(raw)
            }
            return .transferRequest(direction: direction, token: token, path: path, size: size)
        case PeerCode.placeInQueueResponse:
            let path = try reader.string()
            return .placeInQueue(path: path, place: Int(try reader.u32()))
        case PeerCode.uploadFailed:
            return .uploadFailed(path: try reader.string())
        case PeerCode.uploadDenied:
            let path = try reader.string()
            return .uploadDenied(path: path, reason: try reader.string())
        default:
            return .other(code: frame.code)
        }
    }
}

/// A decoded FileSearchResponse (peer code 9), before it is turned into `SearchResultFile`s.
struct SearchResponse: Sendable, Equatable {
    struct File: Sendable, Equatable {
        var path: String
        var size: Int64
        var attributes: [UInt32: UInt32]
    }

    var username: String
    var token: UInt32
    var files: [File]
    var freeSlot: Bool
    var uploadSpeed: UInt32
    var queueLength: UInt32

    static func parse(_ bytes: [UInt8]) throws(WireError) -> SearchResponse {
        var reader = WireReader(bytes)
        let username = try reader.string()
        let token = try reader.u32()
        let count = try reader.count()
        var files: [File] = []
        files.reserveCapacity(min(count, 4096))
        for _ in 0..<count {
            _ = try reader.u8()
            let path = try reader.string()
            let rawSize = try reader.u64()
            _ = try reader.string()  // extension; unreliable, the path is used instead
            let attributeCount = try reader.count()
            guard attributeCount <= 64 else { throw .countTooLarge(attributeCount) }
            var attributes: [UInt32: UInt32] = [:]
            for _ in 0..<attributeCount {
                let key = try reader.u32()
                attributes[key] = try reader.u32()
            }
            guard rawSize <= UInt64(Int64.max) else { throw .malformed("file size") }
            files.append(File(path: path, size: Int64(rawSize), attributes: attributes))
        }
        // The trailer grew over protocol versions; read what is present and default the rest.
        var freeSlot = false
        var speed: UInt32 = 0
        var queue: UInt32 = 0
        if !reader.isAtEnd { freeSlot = try reader.bool() }
        if reader.remaining >= 4 { speed = try reader.u32() }
        if reader.remaining >= 4 { queue = try reader.u32() }
        return SearchResponse(
            username: username, token: token, files: files, freeSlot: freeSlot, uploadSpeed: speed, queueLength: queue)
    }

    /// The files as public results, attributed to the server-authenticated `peer`.
    func results(peer: String) -> [SearchResultFile] {
        files.map { file in
            SearchResultFile(
                peer: peer, path: file.path, sizeBytes: file.size,
                bitsPerSample: file.attributes[5].map(Int.init), sampleRate: file.attributes[4].map(Int.init),
                bitrate: file.attributes[0].map(Int.init), durationSeconds: file.attributes[1].map(Int.init),
                freeSlot: freeSlot, uploadSpeed: Int(uploadSpeed), queueLength: Int(queueLength))
        }
    }
}
