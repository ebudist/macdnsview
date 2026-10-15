import Foundation
import Network

public enum Cloudflare {
    public enum Match: Equatable, Sendable {
        case range(String)
        case nameserver
    }

    static let ranges = [
        "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
        "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
        "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
        "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32",
        "2a06:98c0::/29", "2c0f:f248::/32",
    ]

    private static let networks: [(cidr: String, bytes: Data, bits: Int)] = ranges.compactMap { cidr in
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let bits = Int(parts[1]), let bytes = bytes(String(parts[0])) else { return nil }
        return (cidr, bytes, bits)
    }

    private static func bytes(_ ip: String) -> Data? {
        IPv4Address(ip)?.rawValue ?? IPv6Address(ip)?.rawValue
    }

    public static func range(of ip: String) -> String? {
        guard let address = bytes(ip) else { return nil }
        return networks.first { network in
            guard network.bytes.count == address.count else { return false }
            let whole = network.bits / 8, rest = network.bits % 8
            guard address.prefix(whole) == network.bytes.prefix(whole) else { return false }
            guard rest > 0 else { return true }
            let mask = UInt8(0xFF) << (8 - rest)
            return address[address.startIndex + whole] & mask == network.bytes[network.bytes.startIndex + whole] & mask
        }?.cidr
    }

    public static func isNameserver(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.hasSuffix(".cloudflare.com")
    }

    public static func match(_ row: Row) -> Match? {
        guard row.error == nil, row.section == .answer else { return nil }
        switch row.type {
        case .a, .aaaa: return range(of: row.address).map(Match.range)
        case .ns: return isNameserver(row.name) ? .nameserver : nil
        default: return nil
        }
    }
}
