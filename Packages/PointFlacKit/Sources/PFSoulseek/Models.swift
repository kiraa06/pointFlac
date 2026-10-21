import Foundation

/// One file from one peer's search response.
///
/// Field names follow contract 1's `RemoteTrack` and stream E's `CandidateFile`, so the adapters are field copies.
/// `peer` is the username the *server* gave in its `ConnectToPeer` message, not the name the peer wrote into its own
/// response, because peers are unauthenticated (spec §5.6).
public struct SearchResultFile: Sendable, Hashable, Identifiable {
    /// Stable per peer and path, so duplicate responses collapse and the UI can key rows. A hash, so it carries no NUL
    /// or path characters into `RemoteTrack.id`.
    public let id: String
    /// Read-only: `id`, `fileName` and `folder` are derived from these, and downloads re-derive the local name.
    public private(set) var peer: String
    /// The remote path exactly as the peer sent it (backslash separated). Only ever sent back to that peer.
    public private(set) var path: String
    /// A sanitised base name that is safe to use locally (see `PathSanitizer`).
    public private(set) var fileName: String
    /// The remote folder, for grouping results by peer and folder (§4.7).
    public private(set) var folder: String
    public var sizeBytes: Int64
    /// Attribute 5. `nil` when the peer did not say.
    public var bitsPerSample: Int?
    /// Attribute 4, in hertz.
    public var sampleRate: Int?
    /// Attribute 0, in kbit/s.
    public var bitrate: Int?
    /// Attribute 1.
    public var durationSeconds: Int?
    public var freeSlot: Bool
    /// The peer's average upload speed in bytes per second, as it reports it.
    public var uploadSpeed: Int
    public var queueLength: Int

    public init(
        peer: String, path: String, sizeBytes: Int64, bitsPerSample: Int? = nil, sampleRate: Int? = nil,
        bitrate: Int? = nil, durationSeconds: Int? = nil, freeSlot: Bool = true, uploadSpeed: Int = 0,
        queueLength: Int = 0
    ) {
        self.id = PathSanitizer.resultID(peer: peer, path: path)
        self.peer = peer
        self.path = path
        self.fileName = PathSanitizer.localFileName(forRemotePath: path)
        self.folder = PathSanitizer.remoteFolder(of: path)
        self.sizeBytes = sizeBytes
        self.bitsPerSample = bitsPerSample
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.durationSeconds = durationSeconds
        self.freeSlot = freeSlot
        self.uploadSpeed = uploadSpeed
        self.queueLength = queueLength
    }

    /// FLAC-only policy (§2): only names ending in `.flac` are offered. The bytes are still validated after download.
    public var isFLAC: Bool { path.lowercased().hasSuffix(".flac") }
}

/// Tunables for one search.
public struct SoulseekSearchOptions: Sendable {
    /// How long results are collected. The live probe saw most results within 20 to 30 seconds.
    public var window: Duration = .seconds(25)
    /// Early stop: finish once this many files have been delivered.
    public var maxFiles = 2_000
    /// Results are delivered in batches at this interval rather than one peer at a time, so the UI redraws calmly.
    public var batchInterval: Duration = .milliseconds(250)
    /// Drop non-FLAC files (§2). Off only in tests.
    public var flacOnly = true

    public init(window: Duration = .seconds(25), maxFiles: Int = 2_000, flacOnly: Bool = true) {
        self.window = window
        self.maxFiles = maxFiles
        self.flacOnly = flacOnly
    }
}

/// Client-wide settings. The defaults come from tonight's live probe; tests shorten the timeouts.
public struct SoulseekConfiguration: Sendable {
    public var serverHost = "server.slsknet.org"
    public var serverPort: UInt16 = 2242
    /// Protocol major version. §5.6: 177 is the number for experimental clients, used in development; pointFlac asks
    /// the Soulseek admins for its own number before any wider release. Both 177 and 160 (minor 1) logged in and
    /// searched on the live server on 2026-10-21.
    public var majorVersion: UInt32 = 177
    public var minorVersion: UInt32 = 1
    /// Port advertised with SetWaitPort. Behind NAT nothing connects to it; peers fall back to ConnectToPeer.
    public var listenPort: UInt32 = 2234
    public var connectTimeout: Duration = .seconds(10)
    public var loginTimeout: Duration = .seconds(15)
    /// Interval between ServerPing keepalives.
    public var keepaliveInterval: Duration = .seconds(120)
    /// Reconnect after an unexpected drop. Never after being kicked (Relogged).
    public var autoReconnect = true
    public var reconnectDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]
    /// The server sends ExcludedSearchPhrases shortly after login. A search started before it arrives waits up to this
    /// long, so a forbidden phrase is never sent just because the user typed fast.
    public var excludedPhrasesWait: Duration = .seconds(3)
    /// Minimum gap between two searches (§4.6: "rate-limited, with at least a few seconds between them").
    public var searchMinimumInterval: Duration = .seconds(5)
    /// Peer connections in flight at once (connecting or reading). The probe saw ~23,000 requests in 30 s.
    public var maxConcurrentPeerConnections = 300
    public var peerConnectTimeout: Duration = .seconds(4)
    /// How long a pierced search connection may stay silent before it is dropped. Honest peers answer within a second
    /// or two of the pierce; a silent one holds one of the capped slots that the next peer could use.
    public var peerReadTimeout: Duration = .seconds(6)
    /// Stop accepting new search peers this long before the window closes; they would not answer in time.
    public var searchTailCutoff: Duration = .seconds(2)
    /// How long to wait for the server to answer GetPeerAddress.
    public var peerAddressTimeout: Duration = .seconds(10)
    /// How long a download may wait for the peer's TransferRequest (in its upload queue) before it fails.
    public var transferRequestTimeout: Duration = .seconds(600)
    /// How long a folder listing (album preview) may take to arrive.
    public var browseTimeout: Duration = .seconds(30)
    /// How long the F connection may take to appear after we accepted a TransferRequest.
    public var fileConnectionTimeout: Duration = .seconds(60)
    /// A transfer that receives no bytes for this long fails (and can resume later).
    public var transferIdleTimeout: Duration = .seconds(60)
    /// Connections at once to one peer, of any kind. A peer cannot occupy the search budget through many tokens.
    public var maxConnectionsPerPeer = 4
    /// Absolute lifetime of a search connection (capped further by the search window), against slowloris peers.
    public var searchConnectionLifetime: Duration = .seconds(30)
    /// Responses inflated and parsed at once across all peers. With 1 MiB frames and 16 MiB inflate this bounds the
    /// transient memory to tens of megabytes, far from iOS's jetsam limits.
    public var maxConcurrentParses = 4
    /// Largest file accepted. FLAC albums' longest tracks are far below this; anything larger is hostile or wrong.
    public var maxFileSize: Int64 = 2 * 1024 * 1024 * 1024
    /// Free space where downloads land. Injectable for tests.
    public var availableCapacity: @Sendable (URL) -> Int64? = { url in
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
    /// Peer addresses from the server that are loopback, private (RFC 1918), link-local, multicast or unspecified are
    /// refused: a hostile server must not aim connections into the user's own network. Tests turn this on.
    public var allowPrivatePeerAddresses = false

    public init() {}
}

public enum SoulseekConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case loggedIn(username: String)
    case reconnecting(attempt: Int)
    /// The server logged us out because the account signed in elsewhere (Relogged). No automatic reconnect.
    case kicked
    case failed(SoulseekError)
}

public enum SoulseekError: Error, Sendable, Equatable {
    case invalidPassword
    case invalidUsername
    case invalidVersion
    /// Any other login refusal, with the server's reason (for example SVRFULL).
    case rejected(String)
    case serverUnavailable
    case timeout
    case notLoggedIn
    case kicked
    case connectionLost
    /// The query contains a phrase the server asked clients not to search for.
    case excludedPhrase
    case emptyQuery
    case protocolViolation(String)
}

public enum SoulseekTransferFailure: Error, Sendable, Equatable {
    case notLoggedIn
    case notFLAC
    case peerOffline
    case peerUnreachable
    case denied(String)
    case uploadFailed
    /// The peer announced a different size than the search result (§5.6). Larger is hostile; smaller would end in a
    /// truncated file reported as finished.
    case sizeMismatch(expected: Int64, announced: Int64)
    case timeout
    case incomplete(received: Int64, expected: Int64)
    case cancelled
    /// The same peer and path is already downloading.
    case alreadyInProgress
    /// Larger than `maxFileSize`.
    case fileTooLarge
    /// Not enough free space for the rest of the file.
    case insufficientStorage
    case io(String)
    case protocolViolation(String)
}

public enum SoulseekTransferEvent: Sendable, Equatable {
    /// QueueUpload was sent to the peer.
    case requested
    /// The peer reported our place in its upload queue.
    case remotelyQueued(place: Int)
    /// File bytes are about to flow. `offset` is non-zero when resuming.
    case started(offset: Int64, size: Int64)
    case progress(received: Int64, size: Int64)
    /// The complete file, in its own folder inside the staging directory. The caller validates it (§5.3).
    case finished(URL)
    case failed(SoulseekTransferFailure)
}
