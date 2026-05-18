import Foundation
import SystemConfiguration
import ControllerShared

enum ConnectionHints {
    static func printStartupHints(port: UInt16) {
        let hostCandidates = manualHostCandidates()
        let ipCandidates = ipv4Candidates()

        if !hostCandidates.isEmpty {
            print("Manual host candidates for iPad:")
            hostCandidates.forEach { candidate in
                print("  - \(candidate)")
            }
        }

        if !ipCandidates.isEmpty {
            print("Manual IPv4 candidates for iPad:")
            ipCandidates.forEach { address in
                print("  - \(address):\(port)")
            }
        }

        print("On iPad, prefer a `.local` host above before falling back to a raw IP.")
        print("If discovery fails, make sure only one MacCompanionCLI instance is running.")
    }

    static func preferredPairingPayload(port: UInt16) -> RemotePairingPayload? {
        let host = manualHostCandidates().first ?? preferredIPv4Candidate()
        guard let host else {
            return nil
        }

        return RemotePairingPayload(
            host: host,
            port: port,
            displayName: Host.current().localizedName ?? Host.current().name
        )
    }

    private static func manualHostCandidates() -> [String] {
        var candidates = OrderedStrings()

        if let localHostName = SCDynamicStoreCopyLocalHostName(nil) as String? {
            candidates.append("\(localHostName).local")
        }

        let processHostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !processHostName.isEmpty {
            candidates.append(processHostName)

            if !processHostName.contains(".") {
                candidates.append("\(processHostName).local")
            }
        }

        if let hostName = Host.current().name?.trimmingCharacters(in: .whitespacesAndNewlines), !hostName.isEmpty {
            candidates.append(hostName)
        }

        return candidates.values
    }

    private static func ipv4Candidates() -> [String] {
        var addresses = OrderedStrings()
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }

        defer {
            freeifaddrs(first)
        }

        for cursor in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = cursor.pointee

            guard let address = interface.ifa_addr else {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback, address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostnameBuffer,
                socklen_t(hostnameBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else {
                continue
            }

            let ip = String(cString: hostnameBuffer)
            guard !ip.isEmpty else {
                continue
            }

            addresses.append(ip)
        }

        return addresses.values
    }

    private static func preferredIPv4Candidate() -> String? {
        ipv4Candidates().first(where: { !$0.hasPrefix("169.254.") }) ?? ipv4Candidates().first
    }
}

private struct OrderedStrings {
    private var seen: Set<String> = []
    private(set) var values: [String] = []

    mutating func append(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else {
            return
        }

        seen.insert(trimmed)
        values.append(trimmed)
    }
}
