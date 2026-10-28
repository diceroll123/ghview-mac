import Foundation

public enum ReposQuery {
    public static let query = """
    query($login: String!, $first: Int!, $after: String) {
      rateLimit { remaining limit cost resetAt used nodeCount }
      repositoryOwner(login: $login) {
        repositories(first: $first, after: $after, orderBy: {field: PUSHED_AT, direction: DESC}, ownerAffiliations: OWNER) {
          pageInfo { hasNextPage endCursor }
          nodes {
            name owner { login } primaryLanguage { name } pushedAt stargazerCount
            isArchived isPrivate visibility viewerPermission autoMergeAllowed hasIssuesEnabled
            squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed isFork
            latestRelease { tagName publishedAt }
            pullRequests(states: OPEN) { totalCount }
          }
        }
      }
    }
    """

    struct Response: Decodable, Sendable {
        var rateLimit: RateLimit
        var repositoryOwner: Owner?
        struct Owner: Decodable, Sendable { var repositories: Conn }
        struct Conn: Decodable, Sendable {
            var pageInfo: Info
            var nodes: [Node?]
        }
        struct Info: Decodable, Sendable { var hasNextPage: Bool; var endCursor: String? }
        struct Node: Decodable, Sendable {
            var name: String
            var owner: Login
            var primaryLanguage: Lang?
            var pushedAt: Date?
            var stargazerCount: Int
            var isArchived: Bool
            var isPrivate: Bool
            var visibility: String?
            var viewerPermission: String?
            var autoMergeAllowed: Bool
            var hasIssuesEnabled: Bool
            var squashMergeAllowed: Bool?
            var mergeCommitAllowed: Bool?
            var rebaseMergeAllowed: Bool?
            var isFork: Bool?
            var latestRelease: Release?
            var pullRequests: Count
        }
        struct Login: Decodable, Sendable { var login: String }
        struct Lang: Decodable, Sendable { var name: String }
        struct Count: Decodable, Sendable { var totalCount: Int }
        struct Release: Decodable, Sendable { var tagName: String; var publishedAt: Date? }
    }

    public struct Page: Sendable {
        public var repos: [RepoInfo]
        public var hasNextPage: Bool
        public var endCursor: String?
        public var rateLimit: RateLimit
    }

    static func map(_ n: Response.Node) -> RepoInfo {
        RepoInfo(
            id: RepoId(owner: n.owner.login, name: n.name),
            language: n.primaryLanguage?.name,
            pushedAt: n.pushedAt,
            stars: n.stargazerCount,
            openPRs: n.pullRequests.totalCount,
            isArchived: n.isArchived,
            isPrivate: n.isPrivate,
            visibility: RepoVisibility(graphQL: n.visibility),
            canPush: ["WRITE", "MAINTAIN", "ADMIN"].contains(n.viewerPermission ?? ""),
            allowAutoMerge: n.autoMergeAllowed,
            hasIssues: n.hasIssuesEnabled,
            isFork: n.isFork ?? false,
            allowedMergeMethods: MergeMethod.allCases.filter {
                switch $0 {
                case .squash: n.squashMergeAllowed ?? true
                case .merge: n.mergeCommitAllowed ?? true
                case .rebase: n.rebaseMergeAllowed ?? true
                }
            },
            releaseTag: n.latestRelease?.tagName,
            releaseDate: n.latestRelease?.publishedAt
        )
    }

    public static func fetch(owner: String, first: Int = 50, after: String? = nil, client: GraphQLClient) async throws -> Page {
        let r: Response = try await client.query(query, variables: ["login": owner, "first": first, "after": after])
        guard let conn = r.repositoryOwner?.repositories else { throw GraphQLError(messages: ["owner not found: \(owner)"]) }
        return Page(repos: conn.nodes.compactMap { $0 }.map(map), hasNextPage: conn.pageInfo.hasNextPage,
                    endCursor: conn.pageInfo.endCursor, rateLimit: r.rateLimit)
    }

    // MARK: Individual repositories

    static let infoFields = """
    name owner { login } primaryLanguage { name } pushedAt stargazerCount
    isArchived isPrivate visibility viewerPermission autoMergeAllowed hasIssuesEnabled
            squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed isFork
    latestRelease { tagName publishedAt }
    pullRequests(states: OPEN) { totalCount }
    """

    /// One aliased query for several repositories, so a PR's permissions never depend on the repo list having
    /// been enumerated. Names are validated before they are used, but they still travel as variables.
    static func infoQuery(count: Int) -> String {
        let decls = (0..<count).map { "$o\($0): String!, $n\($0): String!" }.joined(separator: ", ")
        let fields = (0..<count).map { "r\($0): repository(owner: $o\($0), name: $n\($0)) { \(infoFields) }" }.joined(separator: "\n")
        return "query(\(decls)) { rateLimit { remaining limit cost resetAt used nodeCount }\n\(fields) }"
    }

    struct InfoResponse: Decodable, Sendable {
        var rateLimit: RateLimit
        var repos: [Response.Node?]

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            rateLimit = try c.decode(RateLimit.self, forKey: Key(stringValue: "rateLimit")!)
            var out: [Response.Node?] = []
            var i = 0
            while let key = Key(stringValue: "r\(i)"), c.contains(key) {
                out.append(try c.decode(Response.Node?.self, forKey: key))
                i += 1
            }
            repos = out
        }
    }

    /// Metadata and the viewer's permissions for exactly these repositories. A repository GitHub does not return
    /// (missing or inaccessible) is absent from the result.
    public static func fetchInfo(_ ids: [RepoId], client: GraphQLClient, chunk: Int = 20) async throws
        -> (repos: [RepoInfo], rateLimits: [RateLimit]) {
        var out: [RepoInfo] = [], limits: [RateLimit] = []
        for start in stride(from: 0, to: ids.count, by: chunk) {
            let part = Array(ids[start..<min(start + chunk, ids.count)])
            var vars: [String: Any?] = [:]
            for (i, id) in part.enumerated() { vars["o\(i)"] = id.owner; vars["n\(i)"] = id.name }
            let r: InfoResponse = try await client.query(infoQuery(count: part.count), variables: vars)
            out += r.repos.compactMap { $0 }.map(map)
            limits.append(r.rateLimit)
        }
        return (out, limits)
    }
}
