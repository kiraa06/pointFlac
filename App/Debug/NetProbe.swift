#if DEBUG
    import Foundation
    import Network
    import os

    /// Debug-only network probe, run at launch with `-PFNetProbe`. Logs what iOS reports for a few outbound TCP
    /// connections and for the current network path, to tell apart "raw IPv4 literals fail" from "everything fails"
    /// on a device (Soulseek peers are reached by IPv4 literal; the Soulseek server by host name).
    enum NetProbe {
        private static let log = Logger(subsystem: "app.pointflac", category: "netprobe")

        static func runIfRequested() {
            guard ProcessInfo.processInfo.arguments.contains("-PFNetProbe") else { return }
            let queue = DispatchQueue(label: "netprobe")
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                let interfaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ",")
                log.info(
                    """
                    NetProbe path: status=\(String(describing: path.status), privacy: .public) \
                    ipv4=\(path.supportsIPv4, privacy: .public) ipv6=\(path.supportsIPv6, privacy: .public) \
                    dns=\(path.supportsDNS, privacy: .public) expensive=\(path.isExpensive, privacy: .public) \
                    constrained=\(path.isConstrained, privacy: .public) interfaces=\(interfaces, privacy: .public)
                    """)
            }
            monitor.start(queue: queue)
            let targets: [(String, NWEndpoint)] = [
                ("ipv4 literal 1.1.1.1:443", .hostPort(host: .ipv4(IPv4Address("1.1.1.1")!), port: 443)),
                ("ipv4 as name 1.1.1.1:443", .hostPort(host: .name("1.1.1.1", nil), port: 443)),
                ("hostname one.one.one.one:443", .hostPort(host: .name("one.one.one.one", nil), port: 443)),
                ("slsk server by name :2242", .hostPort(host: .name("server.slsknet.org", nil), port: 2242)),
                ("ipv4 literal 8.8.8.8:53", .hostPort(host: .ipv4(IPv4Address("8.8.8.8")!), port: 53)),
            ]
            for (label, endpoint) in targets {
                let connection = NWConnection(to: endpoint, using: .tcp)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .waiting, .failed:
                        let path = connection.currentPath.map { "\($0.status) v4=\($0.supportsIPv4)" } ?? "-"
                        log.info(
                            """
                            NetProbe \(label, privacy: .public): \(String(describing: state), privacy: .public) \
                            path=\(path, privacy: .public)
                            """)
                        connection.cancel()
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
            queue.asyncAfter(deadline: .now() + 15) { monitor.cancel() }
        }
    }
#endif
