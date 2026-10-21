import Network
import Testing

@testable import PFSoulseek

/// The NAT64 path itself can only be exercised on an IPv6-only network (an iPhone on IPv6-only mobile data, verified
/// by hand). These pin the behaviour everywhere else: IPv4 literals stay IPv4, names and IPv6 pass through.
@Suite struct AddressSynthesisTests {
    @Test func ipv4LiteralStaysIPv4OnAnIPv4Network() async {
        let host = await AddressSynthesis.host(for: "93.184.216.34")
        switch host {
        case .ipv4(let address): #expect(address == IPv4Address("93.184.216.34"))
        case .ipv6: break  // acceptable only on a NAT64 network; the host test machine is IPv4
        default: Issue.record("expected an IP address, got \(host)")
        }
    }

    @Test func hostNamesPassThrough() async {
        let host = await AddressSynthesis.host(for: "server.slsknet.org")
        #expect(host == NWEndpoint.Host("server.slsknet.org"))
    }

    @Test func ipv6LiteralsPassThrough() async {
        let host = await AddressSynthesis.host(for: "2001:db8::1")
        #expect(host == NWEndpoint.Host("2001:db8::1"))
    }

    @Test func manyConcurrentLookupsComplete() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<300 {
                group.addTask { _ = await AddressSynthesis.host(for: "93.184.\(index % 250).1") }
            }
        }
    }
}
