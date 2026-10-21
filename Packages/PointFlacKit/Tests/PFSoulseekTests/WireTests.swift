import Foundation
import Testing

@testable import PFSoulseek

@Suite("Wire format")
struct WireTests {
    @Test("Login matches the live-verified layout: name, password, version, md5(name+password) hex, minor")
    func loginGolden() {
        let bytes = Outgoing.login(username: "alice", password: "secret", major: 160, minor: 1)
        var expected: [UInt8] = []
        func u32(_ v: UInt32) {
            expected += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
        }
        func str(_ s: String) {
            u32(UInt32(s.utf8.count))
            expected += Array(s.utf8)
        }
        u32(1)
        str("alice")
        str("secret")
        u32(160)
        str("c4e31313222cf05fcdd1fc068af5570e")  // md5("alicesecret"), computed with Python's hashlib
        u32(1)
        let body = expected
        expected = []
        u32(UInt32(body.count))
        expected += body
        #expect(bytes == expected)
    }

    @Test("PierceFireWall is u32 length 5, u8 code 0, u32 token")
    func pierceGolden() {
        #expect(Outgoing.pierceFireWall(token: 0x0102_0304) == [5, 0, 0, 0, 0, 4, 3, 2, 1])
    }

    @Test("PeerInit, FileSearch, HaveNoParent and FileOffset layouts")
    func otherGoldens() {
        #expect(
            Outgoing.peerInit(username: "a", type: "P")
                == [15, 0, 0, 0, 1, 1, 0, 0, 0, 0x61, 1, 0, 0, 0, 0x50, 0, 0, 0, 0])
        #expect(
            Outgoing.fileSearch(token: 7, query: "ab") == [
                14, 0, 0, 0, 26, 0, 0, 0, 7, 0, 0, 0, 2, 0, 0, 0, 0x61, 0x62,
            ])
        #expect(Outgoing.haveNoParent() == [5, 0, 0, 0, 71, 0, 0, 0, 1])
        #expect(Outgoing.fileOffset(0x0102) == [2, 1, 0, 0, 0, 0, 0, 0])
        #expect(Outgoing.sharedNothing() == [12, 0, 0, 0, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test("Reader throws on truncation and on hostile lengths instead of trapping")
    func readerBounds() throws {
        var short = WireReader([1, 2])
        #expect(throws: WireError.truncated) { try short.u32() }
        var hugeString = WireReader([0xFF, 0xFF, 0xFF, 0xFF, 0x41])
        #expect(throws: WireError.stringTooLong(Int(UInt32.max))) { try hugeString.string() }
        var hugeCount = WireReader([0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: WireError.countTooLarge(0x7FFF_FFFF)) { try hugeCount.count() }
        var ip = WireReader([1, 0, 0, 127])
        #expect(try ip.ipv4() == "127.0.0.1")
    }

    @Test("Invalid UTF-8 decodes with replacement characters, never a crash")
    func lenientStrings() throws {
        var reader = WireReader([2, 0, 0, 0, 0xFF, 0x41])
        #expect(try reader.string() == "\u{FFFD}A")
    }
}

@Suite("Framing")
struct FrameBufferTests {
    @Test("Frames split across chunks reassemble")
    func reassembly() throws {
        var buffer = FrameBuffer(maxFrame: 1024)
        let frame = Outgoing.fileSearch(token: 9, query: "hello")
        buffer.append(frame.prefix(3))
        #expect(try buffer.next() == nil)
        buffer.append(frame.dropFirst(3) + Outgoing.ping())
        #expect(try buffer.next()?.code == 26)
        #expect(try buffer.next() == Frame(code: 32, payload: []))
        #expect(try buffer.next() == nil)
    }

    @Test("A length above the cap is rejected after four bytes, before anything is buffered")
    func capBeforeBuffering() {
        var buffer = FrameBuffer(maxFrame: 4096)
        buffer.append([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: WireError.frameTooLarge(Int(UInt32.max))) { try buffer.next() }
        #expect(buffer.bufferedCount == 4)
    }

    @Test("UInt32.max length does not overflow (the message_size + 4 bug)")
    func noOverflow() {
        var buffer = FrameBuffer(maxFrame: Int(UInt32.max))
        buffer.append([0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3, 4])
        #expect((try? buffer.next()) == nil)
    }

    @Test("A frame too short to hold its code is malformed")
    func tooShort() {
        var buffer = FrameBuffer(maxFrame: 64)
        buffer.append([2, 0, 0, 0, 1, 0])
        #expect(throws: WireError.self) { try buffer.next() }
    }

    @Test("Raw bytes after an init frame are kept for the file body")
    func drainAfterInit() throws {
        var buffer = FrameBuffer(maxFrame: 64)
        buffer.append(Outgoing.pierceFireWall(token: 1) + [9, 9, 9])
        #expect(try buffer.next(codeWidth: .u8)?.code == 0)
        #expect(buffer.drain() == [9, 9, 9])
    }
}

@Suite("Inflate")
struct InflateTests {
    @Test("Round trip")
    func roundTrip() throws {
        let input = Array("The Mountain Goats - Tallahassee".utf8) + [UInt8](repeating: 7, count: 100_000)
        #expect(try Inflate.zlib(Mock.zlib(input), limit: 1 << 20) == input)
    }

    @Test("A decompression bomb stops at the cap")
    func bomb() {
        let bomb = Mock.zlib([UInt8](repeating: 0, count: 20 * 1024 * 1024))
        #expect(bomb.count < 100_000)
        #expect(throws: WireError.inflatedTooLarge(Inflate.searchResponseLimit)) {
            try Inflate.zlib(bomb, limit: Inflate.searchResponseLimit)
        }
    }

    @Test("Bad header, bad checksum and truncation are rejected")
    func corrupt() {
        let good = Mock.zlib(Array(repeating: 65, count: 5000))
        var badChecksum = good
        badChecksum[badChecksum.count - 1] ^= 0xFF
        #expect(throws: WireError.inflateFailed) { try Inflate.zlib(badChecksum, limit: 1 << 20) }
        #expect(throws: WireError.inflateFailed) { try Inflate.zlib([0x12, 0x34] + good.dropFirst(2), limit: 1 << 20) }
        #expect(throws: WireError.self) { try Inflate.zlib(Array(good.prefix(good.count / 2)), limit: 1 << 20) }
    }
}

@Suite("Messages")
struct MessageTests {
    @Test("ConnectToPeer parses the reversed IP, port and token")
    func connectToPeer() throws {
        let bytes = Mock.connectToPeer(username: "bob", type: "P", port: 2234, token: 42)
        var buffer = FrameBuffer(maxFrame: 4096)
        buffer.append(bytes)
        let message = try ServerMessage.parse(try #require(try buffer.next()))
        #expect(
            message
                == .connectToPeer(ConnectRequest(username: "bob", type: "P", ip: "127.0.0.1", port: 2234, token: 42)))
    }

    @Test("Login replies and excluded phrases")
    func loginReplies() throws {
        func parse(_ bytes: [UInt8]) throws -> ServerMessage {
            var buffer = FrameBuffer(maxFrame: 4096)
            buffer.append(bytes)
            return try ServerMessage.parse(try #require(try buffer.next()))
        }
        #expect(try parse(Mock.loginSuccess(greeting: "hi")) == .loginSucceeded(greeting: "hi"))
        #expect(try parse(Mock.loginFailure("INVALIDPASS")) == .loginFailed(reason: "INVALIDPASS"))
        #expect(try parse(Mock.excludedPhrases(["a b", "c"])) == .excludedPhrases(["a b", "c"]))
        #expect(try parse(Mock.relogged) == .relogged)
    }

    @Test("FileSearchResponse: attributes 4 (rate) and 5 (depth), slot, speed, queue")
    func searchResponse() throws {
        let payload = Mock.searchResponsePayload(
            username: "liar", token: 5,
            files: [
                Mock.File(
                    path: "Music\\Artist\\Album\\01 Song.flac", size: 30_000_000,
                    attributes: [(4, 96_000), (5, 24), (1, 240)]),
                Mock.File(path: "Music\\x.mp3", size: 5_000_000, attributes: [(0, 320)]),
            ], freeSlot: false, speed: 123_456, queue: 7)
        let response = try SearchResponse.parse(try Inflate.zlib(Mock.zlib(payload), limit: 1 << 20))
        let results = response.results(peer: "bob", filter: ResultFilter(flacOnly: false))
        #expect(results.count == 2)
        let flac = results[0]
        #expect(flac.peer == "bob")  // the server's name, not the one the peer wrote
        #expect(flac.fileName == "01 Song.flac")
        #expect(flac.folder == "Music\\Artist\\Album")
        #expect(flac.sampleRate == 96_000 && flac.bitsPerSample == 24 && flac.durationSeconds == 240)
        #expect(!flac.freeSlot && flac.uploadSpeed == 123_456 && flac.queueLength == 7)
        #expect(flac.isFLAC && !results[1].isFLAC)
    }

    @Test("TransferRequest for an upload to us carries the size")
    func transferRequest() throws {
        var buffer = FrameBuffer(maxFrame: 4096)
        buffer.append(Mock.transferRequest(token: 3, path: "a\\b.flac", size: 99))
        let message = try PeerMessage.parse(try #require(try buffer.next()))
        #expect(message == .transferRequest(direction: 1, token: 3, path: "a\\b.flac", size: 99))
    }
}

@Suite("Path sanitising")
struct PathSanitizerTests {
    @Test(
        "Remote paths reduce to a safe base name",
        arguments: [
            ("Music\\Artist\\01 Track.flac", "01 Track.flac"),
            ("../../etc/passwd", "passwd"),
            ("C:\\..\\..\\evil.FLAC", "evil.flac"),
            ("/absolute/path/x.flac", "x.flac"),
            ("..", "track"),
            ("dir\\.hidden.flac", "hidden.flac"),
            ("a\u{0}b\u{7}c:d.flac", "a_b_c_d.flac"),
            ("", "track"),
            ("folder\\", "folder"),
        ])
    func sanitise(remote: String, local: String) {
        #expect(PathSanitizer.localFileName(forRemotePath: remote) == local)
    }

    @Test("Long names are cut to a byte budget but keep the extension")
    func longNames() {
        let name = PathSanitizer.localFileName(forRemotePath: String(repeating: "é", count: 500) + ".flac")
        #expect(name.utf8.count <= PathSanitizer.maxNameBytes)
        #expect(name.hasSuffix(".flac"))
        let weird = PathSanitizer.localFileName(forRemotePath: "x." + String(repeating: "a", count: 400))
        #expect(weird.utf8.count <= PathSanitizer.maxNameBytes)
    }

    @Test("Transfer folders are deterministic per peer and path, and never contain the path")
    func transferFolder() {
        let a = PathSanitizer.transferFolderName(peer: "bob", path: "..\\..\\x.flac")
        #expect(a == PathSanitizer.transferFolderName(peer: "bob", path: "..\\..\\x.flac"))
        #expect(a != PathSanitizer.transferFolderName(peer: "eve", path: "..\\..\\x.flac"))
        #expect(a.hasPrefix("slsk-") && !a.contains(".") && !a.contains("/"))
    }
}

@Suite("Fuzz smoke")
struct FuzzTests {
    /// SplitMix64, so failures reproduce from the seed.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("Random and mutated input never crashes a parser")
    func parsersSurviveGarbage() {
        var rng = SeededGenerator(state: 0x5EED)
        let validPayload = Mock.searchResponsePayload(
            username: "u", token: 1, files: [Mock.File(path: "a\\b.flac", size: 10, attributes: [(4, 44_100)])])
        let seeds: [[UInt8]] = [
            validPayload, Mock.zlib(validPayload), Mock.connectToPeer(username: "x", type: "F", port: 9, token: 1),
            Mock.transferRequest(token: 1, path: "p", size: 5), Mock.loginSuccess(),
        ]
        for iteration in 0..<20_000 {
            var bytes: [UInt8]
            if iteration % 2 == 0 {
                bytes = (0..<Int.random(in: 0...96, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            } else {
                bytes = seeds[iteration % seeds.count]
                for _ in 0..<Int.random(in: 1...4, using: &rng) where !bytes.isEmpty {
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                }
                if Bool.random(using: &rng) {
                    bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
                }
            }
            let code = UInt32([1, 3, 9, 18, 40, 44, 46, 50, 160].randomElement(using: &rng)!)
            _ = try? ServerMessage.parse(Frame(code: code, payload: bytes))
            _ = try? PeerMessage.parse(Frame(code: code, payload: bytes))
            _ = try? SearchResponse.parse(bytes)
            _ = try? Inflate.zlib(bytes, limit: 1 << 20)
            var buffer = FrameBuffer(maxFrame: 4096)
            buffer.append(bytes)
            while let frame = try? buffer.next() { _ = frame }
        }
    }
}

@Suite("Presentation helpers")
struct PresentationTests {
    @Test("Results group by peer and folder; free slots, fuller folders and faster peers first")
    func grouping() {
        let slow = (1...3).map {
            SearchResultFile(
                peer: "slow", path: "M\\Artist\\Album\\0\($0) T.flac", sizeBytes: 10, bitsPerSample: 16,
                freeSlot: true, uploadSpeed: 10)
        }
        let fast = (1...2).map {
            SearchResultFile(
                peer: "fast", path: "M\\Artist\\Album\\0\($0) T.flac", sizeBytes: 10, bitsPerSample: 24,
                sampleRate: 96_000, freeSlot: true, uploadSpeed: 1000)
        }
        let busy = [SearchResultFile(peer: "busy", path: "x\\y\\1.flac", sizeBytes: 5, freeSlot: false)]
        let groups = SearchResultFolder.group(busy + fast + slow)
        #expect(groups.map(\.peer) == ["slow", "fast", "busy"])
        #expect(groups[0].name == "Album" && groups[0].totalBytes == 30)
        #expect(groups[1].bestBitsPerSample == 24 && groups[1].bestSampleRate == 96_000)
        #expect(groups[0].files.map(\.fileName) == ["01 T.flac", "02 T.flac", "03 T.flac"])
    }

    @Test("Adapter conveniences for contract 1")
    func adapterFields() {
        let file = SearchResultFile(
            peer: "bob", path: "Music\\Artist\\Album\\01 Song.flac", sizeBytes: 9, freeSlot: false, uploadSpeed: 5,
            queueLength: 2)
        #expect(file.displayTitle == "01 Song")
        #expect(file.albumGuess == "Album" && file.artistGuess == "Artist")
        #expect(file.detail["peer"] == "bob" && file.detail["queue"] == "2" && file.detail["freeSlot"] == "0")
        #expect(SoulseekTransferEvent.progress(received: 1, size: 4).fraction == 0.25)
        #expect(SoulseekTransferEvent.requested.fraction == nil)
        #expect(SoulseekTransferFailure.denied("Banned").reason.contains("Banned"))
    }
}

@Suite("Fuzz smoke: folder listings")
struct FolderFuzzTests {
    @Test("Mutated folder listings never crash the parser")
    func listingsSurviveGarbage() {
        var rng = FuzzTests.SeededGenerator(state: 0xF01D)
        var body = WireWriter()
        body.u32(1)
        body.string("a\\b")
        body.u32(1)
        body.string("a\\b")
        body.u32(1)
        body.u8(1)
        body.string("01.flac")
        body.u64(10)
        body.string("")
        body.u32(0)
        let valid = body.bytes
        for _ in 0..<20_000 {
            var bytes = valid
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            _ = try? FolderListing.parse(bytes)
            _ = try? PeerMessage.parse(Frame(code: 37, payload: Mock.zlib(bytes)))
        }
    }
}
