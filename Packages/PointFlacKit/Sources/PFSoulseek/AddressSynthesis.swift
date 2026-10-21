import Darwin
import Foundation
import Network

/// Turns a peer's IPv4 address into something the current network can reach.
///
/// Soulseek hands out peers as raw IPv4 addresses. On an IPv6-only network (common on mobile data, e.g. 464XLAT-less
/// carriers) iOS reaches the IPv4 internet only through NAT64, and Network.framework does not synthesize the NAT64
/// address for an IPv4 literal: the connection waits with "Network is down" (verified on an iPhone on Jio-style
/// IPv6-only cellular, 2026-10-21). Apple's prescribed fix is to pass the literal through `getaddrinfo` with
/// `AI_DEFAULT`, which returns the synthesized IPv6 address on a NAT64 network and the IPv4 address unchanged
/// everywhere else.
///
/// `getaddrinfo` on an address literal does no network I/O once the system knows the NAT64 prefix, so it is fast, but
/// it is still a blocking call: it runs on one private serial queue, never on the cooperative thread pool.
enum AddressSynthesis {
    private static let queue = DispatchQueue(label: "app.pointflac.soulseek.address-synthesis", qos: .userInitiated)

    /// The host to connect to for `literal`. Non-IPv4 strings (host names, IPv6) pass through unchanged.
    static func host(for literal: String) async -> NWEndpoint.Host {
        guard IPv4Address(literal) != nil else { return NWEndpoint.Host(literal) }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: resolve(literal)) }
        }
    }

    /// Synchronous core, for tests and the serial queue. Prefers a synthesized IPv6 address when the resolver offers
    /// one (that only happens on NAT64 networks), else the IPv4 address; falls back to the literal if resolution fails.
    static func resolve(_ literal: String) -> NWEndpoint.Host {
        var hints = addrinfo()
        hints.ai_flags = AI_V4MAPPED_CFG | AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(literal, nil, &hints, &results) == 0, let first = results else {
            return NWEndpoint.Host(literal)
        }
        defer { freeaddrinfo(first) }
        var ipv4: IPv4Address?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let address = info.pointee.ai_addr {
                switch Int32(info.pointee.ai_family) {
                case AF_INET6:
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Data($0) }
                    }
                    if let synthesized = IPv6Address(bytes) { return .ipv6(synthesized) }
                case AF_INET:
                    let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin_addr) { Data($0) }
                    }
                    if ipv4 == nil { ipv4 = IPv4Address(bytes) }
                default:
                    break
                }
            }
            cursor = info.pointee.ai_next
        }
        if let ipv4 { return .ipv4(ipv4) }
        return NWEndpoint.Host(literal)
    }
}
