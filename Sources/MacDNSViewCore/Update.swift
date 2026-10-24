import Foundation

public struct Release: Equatable, Sendable {
    public let version: String
    public let page: URL

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.trimmingPrefix("v").split(separator: ".").map { Int($0) ?? 0 } }
        let (a, b) = (parts(candidate), parts(current))
        for i in 0 ..< max(a.count, b.count) where a[safe: i] != b[safe: i] {
            return a[safe: i] > b[safe: i]
        }
        return false
    }

    public static func latest(session: URLSession = .shared) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ebudist/macdnsview/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let reply = try await session.data(for: request)
        struct Body: Decodable { let tag_name: String; let html_url: URL }
        let body = try JSONDecoder().decode(Body.self, from: reply.0)
        return Release(version: String(body.tag_name.trimmingPrefix("v")), page: body.html_url)
    }
}

private extension [Int] {
    subscript(safe i: Int) -> Int { indices.contains(i) ? self[i] : 0 }
}
