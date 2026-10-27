import Foundation

/// One GraphQL call returns everything the PR list needs: reviews, check rollup,
/// mergeable state, labels and diff stats. Replaces ~5 REST calls per PR.
public enum PullRequestQuery {
    static let fragment = """
    fragment PRFields on PullRequest {
      number title isDraft state createdAt updatedAt url
      headRefName baseRefName headRefOid additions deletions
      mergeStateStatus reviewDecision
      author { login }
      repository { name owner { login } }
      autoMergeRequest { enabledAt }
      viewerLatestReview { state }
      comments { totalCount }
      labels(first: 20) { totalCount nodes { name color } }
      reviewRequests(first: 20) { totalCount nodes { requestedReviewer { ... on User { login } ... on Team { slug organization { login } } } } }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) {
        checkRunCountsByState { state count }
        statusContextCountsByState { state count }
        nodes {
        __typename
        ... on CheckRun { id databaseId name status conclusion detailsUrl checkSuite { workflowRun { workflow { name } } } }
        ... on StatusContext { id context state targetUrl }
      } } } } } }
    }
    """

    public static let repoPRs = """
    query($owner: String!, $name: String!, $first: Int!, $after: String) {
      rateLimit { remaining limit cost resetAt used nodeCount }
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: $first, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes { ...PRFields }
        }
      }
    }
    \(fragment)
    """

    public static let searchPRs = """
    query($q: String!, $first: Int!, $after: String) {
      rateLimit { remaining limit cost resetAt used nodeCount }
      search(query: $q, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes { ...PRFields }
      }
    }
    \(fragment)
    """

    // MARK: Response DTOs

    struct Connection: Decodable, Sendable {
        struct PageInfo: Decodable, Sendable { var hasNextPage: Bool; var endCursor: String? }
        var pageInfo: PageInfo
        var nodes: [Node?]
        /// Search only: how many results match, whatever part of them can actually be paged to.
        var issueCount: Int?
    }
    struct RepoResponse: Decodable, Sendable {
        var rateLimit: RateLimit
        var repository: Repo?
        struct Repo: Decodable, Sendable { var pullRequests: Connection }
    }
    struct SearchResponse: Decodable, Sendable {
        var rateLimit: RateLimit
        var search: Connection
    }

    struct Node: Decodable, Sendable {
        var number: Int?
        var title: String
        var isDraft: Bool
        var state: String
        var createdAt: Date
        var updatedAt: Date
        var url: String
        var headRefName: String
        var baseRefName: String
        var headRefOid: String
        var additions: Int
        var deletions: Int
        var mergeStateStatus: String?
        var reviewDecision: String?
        var author: Login?
        var repository: Repository
        var autoMergeRequest: Present?
        var viewerLatestReview: Review?
        var comments: Count
        var labels: Nodes<Label>
        var reviewRequests: Nodes<Request>
        var commits: Nodes<CommitNode>

        struct Login: Decodable, Sendable { var login: String }
        struct Repository: Decodable, Sendable { var name: String; var owner: Login }
        struct Present: Decodable, Sendable { var enabledAt: String? }
        struct Review: Decodable, Sendable { var state: String }
        struct Count: Decodable, Sendable { var totalCount: Int }
        struct Nodes<T: Decodable & Sendable>: Decodable, Sendable { var nodes: [T?]; var totalCount: Int? }
        struct Label: Decodable, Sendable { var name: String; var color: String }
        struct Request: Decodable, Sendable { var requestedReviewer: Reviewer? }
        struct Reviewer: Decodable, Sendable { var login: String?; var slug: String?; var organization: Login? }
        struct CommitNode: Decodable, Sendable { var commit: Commit }
        struct Commit: Decodable, Sendable { var statusCheckRollup: Rollup? }
        struct Rollup: Decodable, Sendable { var contexts: Contexts }
        struct Contexts: Decodable, Sendable {
            var nodes: [Context?]
            var checkRunCountsByState: [StateCount]?
            var statusContextCountsByState: [StateCount]?
        }
        struct StateCount: Decodable, Sendable { var state: String; var count: Int }
        struct Context: Decodable, Sendable {
            var typename: String
            var id: String?
            var databaseId: Int?
            var name: String?
            var status: String?
            var conclusion: String?
            var detailsUrl: String?
            var checkSuite: Suite?
            var context: String?
            var state: String?
            var targetUrl: String?
            enum CodingKeys: String, CodingKey {
                case typename = "__typename"
                case id, databaseId, name, status, conclusion, detailsUrl, checkSuite, context, state, targetUrl
            }
            struct Suite: Decodable, Sendable { var workflowRun: Run? }
            struct Run: Decodable, Sendable { var workflow: Flow? }
            struct Flow: Decodable, Sendable { var name: String }
        }
    }

    // MARK: Mapping

    static func checkStatus(status: String?, conclusion: String?) -> CheckStatus {
        switch status {
        case "IN_PROGRESS", "QUEUED", "WAITING", "PENDING", "REQUESTED": return .pending
        default: break
        }
        switch conclusion {
        case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failing
        case "CANCELLED": return .cancelled
        case "SUCCESS": return .passing
        case "NEUTRAL", "SKIPPED": return .skipped
        default: return .unknown
        }
    }

    static func statusContext(_ state: String?) -> CheckStatus {
        switch state {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return .pending
        default: return .unknown
        }
    }

    static func map(_ n: Node) -> PR? {
        guard let number = n.number else { return nil } // search can return non-PR nodes as {}
        let repo = RepoId(owner: n.repository.owner.login, name: n.repository.name)
        let checks: [CheckRun] = (n.commits.nodes.first??.commit.statusCheckRollup?.contexts.nodes ?? []).compactMap { c in
            guard let c else { return nil }
            if c.typename == "CheckRun" {
                let base = c.name ?? "check"
                let name = c.checkSuite?.workflowRun?.workflow.map { "\($0.name) / \(base)" } ?? base
                return CheckRun(id: c.id ?? name, databaseId: c.databaseId, name: name, url: c.detailsUrl,
                                status: checkStatus(status: c.status, conclusion: c.conclusion))
            } else {
                let name = c.context ?? "status"
                return CheckRun(id: c.id ?? name, name: name, url: c.targetUrl, status: statusContext(c.state))
            }
        }
        // GitHub's own per-state totals are exact; counting the fetched checks is only a fallback.
        let rollupContexts = n.commits.nodes.first??.commit.statusCheckRollup?.contexts
        var checkCounts = CheckCounts(checks: checks)
        if let runs = rollupContexts?.checkRunCountsByState, let statuses = rollupContexts?.statusContextCountsByState {
            checkCounts = CheckCounts(checkRuns: runs.map { .init(state: $0.state, count: $0.count) },
                                      statuses: statuses.map { .init(state: $0.state, count: $0.count) })
        }
        return PR(
            id: PrId(repo: repo, number: number),
            title: n.title,
            author: n.author?.login ?? "ghost",
            isDraft: n.isDraft,
            isOpen: n.state == "OPEN",
            createdAt: n.createdAt,
            updatedAt: n.updatedAt,
            url: n.url,
            headRef: n.headRefName,
            baseRef: n.baseRefName,
            headSha: n.headRefOid,
            additions: n.additions,
            deletions: n.deletions,
            comments: n.comments.totalCount,
            autoMerge: n.autoMergeRequest != nil,
            reviewStatus: ReviewStatus(decision: n.reviewDecision),
            viewerApproved: n.viewerLatestReview?.state == "APPROVED",
            mergeable: MergeableState(graphQL: n.mergeStateStatus),
            requestedReviewers: n.reviewRequests.nodes.compactMap { $0?.requestedReviewer?.login },
            labels: n.labels.nodes.compactMap { $0 }.map { PRLabel(name: $0.name, color: $0.color) },
            checks: checks,
            checkSummary: checkCounts.status, // from the complete totals, not just the first 100 checks
            checkCounts: checkCounts,
            requestedTeams: n.reviewRequests.nodes.compactMap { r in
                guard let t = r?.requestedReviewer, let slug = t.slug else { return nil }
                return ReviewTeam(org: t.organization?.login ?? repo.owner, slug: slug)
            },
            labelTotal: n.labels.totalCount,
            reviewRequestTotal: n.reviewRequests.totalCount
        )
    }

    public struct Page: Sendable {
        public var prs: [PR]
        public var hasNextPage: Bool
        public var endCursor: String?
        public var rateLimit: RateLimit
        /// Search only: the total number of matches.
        public var totalCount: Int?
    }

    static func page(_ conn: Connection, rateLimit: RateLimit) -> Page {
        Page(prs: conn.nodes.compactMap { $0 }.compactMap(map), hasNextPage: conn.pageInfo.hasNextPage,
             endCursor: conn.pageInfo.endCursor, rateLimit: rateLimit, totalCount: conn.issueCount)
    }

    /// Everything in a PR search query except the scope, so chunking can budget the remaining length.
    public static let searchPrefix = "is:pr is:open sort:created-desc "

    // MARK: API

    public static func fetchRepo(_ repo: RepoId, first: Int = 30, after: String? = nil, client: GraphQLClient) async throws -> Page {
        let r: RepoResponse = try await client.query(repoPRs, variables: [
            "owner": repo.owner, "name": repo.name, "first": first, "after": after,
        ])
        guard let conn = r.repository?.pullRequests else { throw GraphQLError(messages: ["repository not found: \(repo.fullName)"]) }
        return page(conn, rateLimit: r.rateLimit)
    }

    /// `scope` is e.g. "org:acme" or "author:octocat".
    public static func fetchSearch(scope: String, first: Int = 30, after: String? = nil, client: GraphQLClient) async throws -> Page {
        let r: SearchResponse = try await client.query(searchPRs, variables: [
            "q": searchPrefix + scope, "first": first, "after": after,
        ])
        return page(r.search, rateLimit: r.rateLimit)
    }
}
