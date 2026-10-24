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
        guard let release = Release(tag: body.tag_name, page: body.html_url) else { throw URLError(.cannotParseResponse) }
        return release
    }

    static let releases = "https://github.com/ebudist/macdnsview/releases/"

    init?(tag: String, page: URL) {
        let version = String(tag.trimmingPrefix("v"))
        guard version.wholeMatch(of: /\d+(\.\d+)*/) != nil else { return nil }
        self.version = version
        self.page = page.absoluteString.hasPrefix(Self.releases) && page.host() == "github.com"
            ? page : URL(string: Self.releases + "tag/v" + version)!
    }
}

private extension [Int] {
    subscript(safe i: Int) -> Int { indices.contains(i) ? self[i] : 0 }
}
