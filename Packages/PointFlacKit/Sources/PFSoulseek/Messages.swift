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
    static let folderContentsRequest: UInt32 = 36
    static let folderContentsResponse: UInt32 = 37
}

enum PeerInitCode {
    static let pierceFireWall: UInt8 = 0
    static let peerInit: UInt8 = 1
}

/// Frame caps (§5.6). Server control traffic is small; the largest legitimate server messages are room and privileged
/// user lists. Peer frames carry compressed search responses, which are far smaller than their inflated form.
enum FrameCaps {
    static let server = 4 * 1024 * 1024
    /// Connections we asked for (downloads, folder listings).
    static let peer = 4 * 1024 * 1024
    /// Connections that only bring a search response. 1 MiB of compressed response is thousands of files.
    static let searchPeer = 1024 * 1024
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

    /// Tells the server we have no distributed-network parent. pointFlac never connects to the parents it is offered
    /// and ignores type "D" connections, so it stays outside the distributed network; its search results arrive only
    /// through server-forwarded ConnectToPeer.
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

    static func folderContentsRequest(token: UInt32, folder: String) -> [UInt8] {
        WireWriter.message(code: PeerCode.folderContentsRequest) {
            $0.u32(token)
            $0.string(folder)
        }
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
    case folderContents(FolderListing)
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
        case PeerCode.folderContentsResponse:
            let inflated = try Inflate.zlib(frame.payload, limit: Inflate.folderListingLimit)
            return .folderContents(try FolderListing.parse(inflated))
        default:
            return .other(code: frame.code)
        }
    }
}

/// A decoded FolderContentsResponse (peer code 37). Entries carry base names; `files` holds full remote paths.
struct FolderListing: Sendable, Equatable {
    /// More entries than any real album folder tree; the 32 MiB inflate cap bounds the work long before this.
    static let maxFiles = 50_000

    var token: UInt32
    var folder: String
    var files: [SearchResponse.File]

    static func parse(_ bytes: [UInt8]) throws(WireError) -> FolderListing {
        var reader = WireReader(bytes)
        let token = try reader.u32()
        let folder = try reader.string()
        let folderCount = try reader.count()
        var files: [SearchResponse.File] = []
        for _ in 0..<folderCount {
            let directory = try reader.string()
            let fileCount = try reader.count()
            guard files.count + fileCount <= maxFiles else { throw .countTooLarge(files.count + fileCount) }
            for _ in 0..<fileCount {
                _ = try reader.u8()
                let name = try reader.string()
                let rawSize = try reader.u64()
                _ = try reader.string()
                let attributeCount = try reader.count()
                guard attributeCount <= 64 else { throw .countTooLarge(attributeCount) }
                var attributes: [UInt32: UInt32] = [:]
                for _ in 0..<attributeCount {
                    let key = try reader.u32()
                    attributes[key] = try reader.u32()
                }
                guard rawSize <= UInt64(Int64.max) else { throw .malformed("file size") }
                files.append(
                    SearchResponse.File(path: directory + "\\" + name, size: Int64(rawSize), attributes: attributes))
            }
        }
        return FolderListing(token: token, folder: folder, files: files)
    }

    /// The listing as results in track order, filtered and sorted in the per-peer task rather than on the actor.
    func results(peer: String, filter: ResultFilter) -> [SearchResultFile] {
        files.filter { filter.admits(path: $0.path, size: $0.size) }
            .map { file in
                SearchResultFile(
                    peer: peer, path: file.path, sizeBytes: file.size, bitsPerSample: file.attributes[5].map(Int.init),
                    sampleRate: file.attributes[4].map(Int.init), bitrate: file.attributes[0].map(Int.init),
                    durationSeconds: file.attributes[1].map(Int.init))
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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

    /// Files kept from one response. A peer may list more (they are skipped, not stored), so one response can never
    /// make the client hold more than this many entries.
    static let maxFilesKept = 2_000

    /// Reads just the token from the first inflated bytes (username, then token), so a response for a search that is
    /// no longer running is dropped without inflating the rest.
    static func token(fromPrefix bytes: [UInt8]) throws(WireError) -> UInt32 {
        var reader = WireReader(bytes, limits: WireLimits(maxString: 512))
        try reader.skipString()
        return try reader.u32()
    }

    static func parse(_ bytes: [UInt8]) throws(WireError) -> SearchResponse {
        var reader = WireReader(bytes)
        let username = try reader.string()
        let token = try reader.u32()
        let count = try reader.count()
        var files: [File] = []
        files.reserveCapacity(min(count, maxFilesKept))
        for index in 0..<count {
            guard index < maxFilesKept else {
                try skipFile(&reader)
                continue
            }
            _ = try reader.u8()
            let path = try reader.string()
            let rawSize = try reader.u64()
            try reader.skipString()  // extension; unreliable, the path is used instead
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

    private static func skipFile(_ reader: inout WireReader) throws(WireError) {
        try reader.skip(1)
        try reader.skipString()
        try reader.skip(8)
        try reader.skipString()
        let attributeCount = try reader.count()
        guard attributeCount <= 64 else { throw .countTooLarge(attributeCount) }
        try reader.skip(attributeCount * 8)
    }

    /// The files as public results, attributed to the server-authenticated `peer`, after the cheap checks on the raw
    /// path (FLAC suffix, excluded phrases, empty files) so that only survivors pay for sanitising and hashing. Runs
    /// in the per-peer task, never on the actor.
    func results(peer: String, filter: ResultFilter = ResultFilter()) -> [SearchResultFile] {
        Array(
            files.lazy
                .filter { filter.admits(path: $0.path, size: $0.size) }
                .prefix(filter.limit)
                .map { file in
                    SearchResultFile(
                        peer: peer, path: file.path, sizeBytes: file.size,
                        bitsPerSample: file.attributes[5].map(Int.init), sampleRate: file.attributes[4].map(Int.init),
                        bitrate: file.attributes[0].map(Int.init), durationSeconds: file.attributes[1].map(Int.init),
                        freeSlot: freeSlot, uploadSpeed: Int(uploadSpeed), queueLength: Int(queueLength))
                })
    }
}

/// The checks a result must pass before it reaches the actor: a snapshot of the search's options and the excluded
/// phrases, so the per-peer task can filter without touching actor state.
struct ResultFilter: Sendable {
    var flacOnly = true
    /// Lower-cased.
    var excludedPhrases: [String] = []
    var limit = SearchResponse.maxFilesKept

    func admits(path: String, size: Int64) -> Bool {
        guard size > 0 else { return false }
        let lowered = path.lowercased()
        if flacOnly && !lowered.hasSuffix(".flac") { return false }
        return !excludedPhrases.contains { lowered.contains($0) }
    }
}
