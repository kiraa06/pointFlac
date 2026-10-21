import Foundation

/// A counting semaphore for async code. It bounds how many peer responses are inflated and parsed at once, so 300
/// hostile peers cannot each hold a 16 MiB inflate buffer at the same moment (iOS would jetsam the app).
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = max(1, permits) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `work` while holding a permit.
    func withPermit<T: Sendable>(_ work: @Sendable () throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try work()
    }
}

/// Which peer addresses the server may send us to.
enum AddressPolicy {
    /// True for a routable public IPv4 address. Loopback, RFC 1918, link-local, CGNAT shared space, multicast,
    /// broadcast and "this network" are refused, so a hostile server cannot aim connections at the user's own LAN
    /// (and the app never triggers iOS's Local Network prompt).
    static func isPublic(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let (a, b) = (parts[0], parts[1])
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b): return false
        case 169 where b == 254: return false
        case 172 where (16...31).contains(b): return false
        case 192 where b == 168: return false
        case 224...255: return false
        default: return true
        }
    }
}
