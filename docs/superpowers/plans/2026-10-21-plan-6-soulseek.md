# pointFlac Plan 6: Soulseek client (soft-launch cut)

**Goal:** a native, hardened Soulseek client in `PFSoulseek` that logs in, searches (through NAT, via server-mediated
indirect connections) and downloads FLAC files into a staging folder, shaped so a thin adapter can satisfy contract 1's
`DownloadProvider`.

**Spec:** §2 (search and download only, no sharing), §3.3 (permissive code only), §4.7 (Soulseek), §5.1, §5.6, §5.8.
**Core decision (spike S4):** native Swift client, not SeeleseekCore. Reasons in `docs/spikes/S4-soulseek-core.md`.

## Architecture

- `PFSoulseek` depends only on Foundation, Network.framework, Compression and CryptoKit. It does not depend on
  `PFDownloads` (feature packages stay independent, §5.1); the controller writes the `DownloadProvider` adapter.
- Build flag: `PFSoulseek` is its own library product. Only the Soulseek build variant links it and defines `SOULSEEK`
  for the App's adapter code, so builds without it contain no Soulseek code (§5.6 "Build flag").
- Layers, bottom up:
  1. `Wire`: `WireWriter` / `WireReader` (strict, bounds-checked, capped strings and counts, never traps).
  2. `FrameBuffer`: incremental length-prefixed framing with a per-connection frame cap checked before buffering.
  3. `Inflate`: zlib inflate (Compression, streaming) with an output cap and Adler-32 check.
  4. `Messages`: typed server and peer messages; builders for what we send, parsers for what we receive.
  5. `TCPLink`: an async wrapper over `NWConnection` with connect and read timeouts.
  6. `SoulseekClient` (actor): login, keepalive, reconnect, search, the indirect-connection hub, downloads.

## Interfaces

```swift
public actor SoulseekClient {
    public init(configuration: SoulseekConfiguration = .init())
    public func login(username: String, password: String) async throws(SoulseekError)
    public func logout()
    public var state: SoulseekConnectionState { get }          // disconnected, connecting, loggedIn, kicked, failed
    public func stateUpdates() -> AsyncStream<SoulseekConnectionState>
    public var excludedPhrases: [String] { get }
    public func search(_ query: String, options: SoulseekSearchOptions = .init())
        -> AsyncThrowingStream<[SearchResultFile], Error>   // batches; ends at the window, the cap or cancellation
    public func download(_ file: SearchResultFile, into staging: URL) -> AsyncStream<SoulseekTransferEvent>
}
public struct SearchResultFile: Sendable, Hashable, Identifiable {   // id = "peer\u{0}path"
    peer, path, fileName (sanitised), folder, sizeBytes, bitsPerSample (attr 5), sampleRate (attr 4),
    bitrate (attr 0), durationSeconds (attr 1), freeSlot, uploadSpeed, queueLength
}
public enum SoulseekTransferEvent { requested, remotelyQueued(place:), started(offset:size:), progress(received:size:),
    finished(URL), failed(SoulseekTransferFailure) }               // the last event is always finished or failed
```

Adapter mapping (controller): `RemoteTrack.id = file.id`, `provider = "soulseek"`, `detail = ["peer", "path",
"freeSlot", "speed", "queue"]`; `requested`/`remotelyQueued` → `.queued`, `progress` → `.progress(received/size)`.

## Tasks

1. **Wire + framing + inflate** (TDD): golden bytes for Login (matches the probe), PierceFireWall (len 5, code 0),
   PeerInit, FileSearch; reader rejects truncation, oversized strings and counts; frame cap rejects before buffering;
   `UInt32.max` length does not overflow; inflate rejects bombs above the cap and bad checksums.
2. **Messages**: parse Login reply (success/failure reason), ConnectToPeer (reversed IP), GetPeerAddress,
   ExcludedSearchPhrases, Relogged; peer FileSearchResponse (attributes, slot, speed, queue), TransferRequest,
   PlaceInQueueResponse, UploadDenied, UploadFailed. Fuzz smoke: random and mutated bytes into every parser.
3. **Login, keepalive, reconnect**: errors `invalidPassword`, `invalidUsername`, `invalidVersion`, `rejected`,
   `serverUnavailable`, `timeout`; `Relogged` (41) → `kicked`, no reconnect; unexpected drop → backoff reconnect.
   After login: SetWaitPort (2), SetStatus online (28), SharedFoldersFiles 0/0 (35), HaveNoParent (71). ServerPing (32)
   on an interval.
4. **Search**: minimum interval between searches (rate limit); refuse queries matching an excluded phrase and drop
   matching results; each `ConnectToPeer` type P → non-blocking connect (cap 300 in flight, 4 s connect timeout,
   per-peer read timeout) → PierceFireWall → FileSearchResponse; FLAC-only; dedupe; batches every 250 ms; early stop at
   `maxFiles`; stop accepting peers shortly before the window closes.
5. **Download**: GetPeerAddress → direct P connection → QueueUpload; PlaceInQueue → `remotelyQueued`; TransferRequest
   (direction upload) on any P connection from that peer, including new indirect ones → size check (never above the
   size from search) → TransferResponse allowed; F connection via `ConnectToPeer` type F → PierceFireWall → read
   FileTransferInit token → send FileOffset → stream to `<staging>/slsk-<hash>/<sanitised>.flac.part`, rename on
   completion. Resume: an existing `.part` sets the offset. Denied, failed, idle and queue timeouts → `failed`.
6. **Hardening sweep**: caps (server 4 MiB, peer 4 MiB, init 4 KiB), inflate 16 MiB (search) / 32 MiB (folders),
   path sanitiser tests (`..`, absolute, backslashes, control characters, reserved names, length), no uploads: incoming
   `TransferRequest` direction download, `QueueUpload`, browse and user-info requests are refused or ignored.
7. **Live test** (`PF_LIVE_TESTS=1`, credentials from env `KM_USERNAME` / `KM_PASSWORD`): login and one search.

## Tests (host, Swift Testing, `Tests/PFSoulseekTests`)

- A local mock server and mock peers (`NWListener` on 127.0.0.1) drive: login success/failure/timeout/server down,
  kicked, reconnect, search with indirect connects, excluded phrases, download with indirect F connection, resume by
  offset, remote queue place, denial, oversized and malformed frames, size larger than requested, zlib bomb,
  unresponsive peers (read timeout) and the concurrency cap.

## Not in this cut

- Inbound listener (we advertise a port but behind NAT inbound connections never arrive; indirect connections cover it).
- Folder browse (FolderContentsRequest 36/37) for the album preview in §4.7; pause; distributed network beyond
  HaveNoParent; `BGContinuedProcessingTask`.
