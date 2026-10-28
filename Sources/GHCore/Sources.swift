import Foundation

public enum Source: Hashable, Sendable, Codable, Identifiable {
    case user(String)
    case org(String)
    /// One repository, as `owner/name`: its PRs without the rest of its owner's.
    case repo(String)

    public var id: String { name.lowercased() }
    public var name: String {
        switch self { case .user(let n), .org(let n), .repo(let n): n }
    }
    public var displayName: String {
        switch self { case .user(let n): "@\(n)"; case .org(let n), .repo(let n): n }
    }

    /// The account that owns this source (for a repository, the part before the slash).
    public var ownerLogin: String {
        if case .repo(let n) = self { return String(n.prefix { $0 != "/" }) }
        return name
    }

    /// The repository, when this source is one.
    public var repoId: RepoId? {
        guard case .repo(let n) = self else { return nil }
        let parts = n.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? RepoId(owner: parts[0], name: parts[1]) : nil
    }
    /// GitHub serves an avatar for any user or org at `github.com/<login>.png`, with no API call or token.
    /// Names are validated as alphanumerics and hyphens, so they are safe to put in the URL.
    public func avatarURL(pixels: Int = 64) -> URL? {
        URL(string: "https://github.com/\(ownerLogin).png?size=\(pixels)")
    }

    /// The profile or organization page on GitHub.
    public var profileURL: URL { URL(string: "https://github.com/\(name)")! } // for a repository, its own page

    /// GitHub's own pull request search for everything open in this source, the browser twin of the PRs view.
    public var pullRequestsURL: URL {
        var c = URLComponents(string: "https://github.com/pulls")!
        c.queryItems = [URLQueryItem(name: "q", value: "is:pr is:open \(searchScope)")]
        return c.url!
    }

    /// Search qualifier for source-wide PR lists: every PR in the source's repos, not just ones it authored.
    public var searchScope: String {
        switch self { case .user(let n): "user:\(n)"; case .org(let n): "org:\(n)"; case .repo(let n): "repo:\(n)" }
    }
}

public struct SourceConfig: Sendable, Equatable {
    public var includeSelf = true
    public var autoFetchOrgs = true
    public var orgs: [String] = []
    public var users: [String] = []
    public var exclude: [String] = []
    public init() {}
}

public struct Viewer: Sendable, Equatable {
    public var login: String
    public var orgs: [String]
    public init(login: String, orgs: [String]) { self.login = login; self.orgs = orgs }
}

public enum SourcesQuery {
    static let viewerQuery = """
    query($after: String) {
      rateLimit { remaining limit cost resetAt used nodeCount }
      viewer { login organizations(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { login } } }
    }
    """

    struct ViewerResponse: Decodable, Sendable {
        var rateLimit: RateLimit
        var viewer: V
        struct V: Decodable, Sendable {
            var login: String
            var organizations: Orgs
        }
        struct Orgs: Decodable, Sendable {
            var pageInfo: PageInfo
            var nodes: [Org?]
        }
        struct PageInfo: Decodable, Sendable { var hasNextPage: Bool; var endCursor: String? }
        struct Org: Decodable, Sendable { var login: String }
    }

    public static func fetchViewer(client: GraphQLClient) async throws -> Viewer {
        var orgs: [String] = []
        var after: String?
        var login = ""
        repeat {
            let r: ViewerResponse = try await client.query(viewerQuery, variables: ["after": after])
            login = r.viewer.login
            orgs += r.viewer.organizations.nodes.compactMap { $0?.login }
            after = r.viewer.organizations.pageInfo.hasNextPage ? r.viewer.organizations.pageInfo.endCursor : nil
        } while after != nil
        return Viewer(login: login, orgs: orgs)
    }

    /// Self, then auto-fetched orgs (alphabetical), configured orgs, configured users.
    /// Deduped case-insensitively; `exclude` applies to everything.
    public static func assemble(viewer: Viewer, config: SourceConfig) -> [Source] {
        let excluded = Set(config.exclude.map { $0.lowercased() })
        var seen = Set<String>()
        var out: [Source] = []
        func add(_ s: Source) {
            let key = s.name.lowercased()
            guard !excluded.contains(key), seen.insert(key).inserted else { return }
            out.append(s)
        }
        if config.includeSelf { add(.user(viewer.login)) }
        if config.autoFetchOrgs {
            viewer.orgs.sorted { $0.lowercased() < $1.lowercased() }.forEach { add(.org($0)) }
        }
        config.orgs.forEach { add(.org($0)) }
        config.users.forEach { add(.user($0)) }
        return out
    }
}
