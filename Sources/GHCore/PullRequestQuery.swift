import Foundation

/// One GraphQL call returns everything the PR list needs: reviews, check rollup,
/// mergeable state, labels and diff stats. Replaces ~5 REST calls per PR.
public enum PullRequestQuery {
    static let fragment = """
    fragment PRFields on PullRequest {
      number title isDraft state createdAt updatedAt url
      headRefName baseRefName headRefOid additions deletions
      mergeable reviewDecision
      author { login }
      repository { name owner { login } }
      autoMergeRequest { enabledAt }
      viewerLatestReview { state }
      comments { totalCount }
      labels(first: 20) { totalCount nodes { name color } }
      reviewRequests { totalCount }
      reviewRequestNodes: reviewRequests(first: 20) @include(if: $needsReviewers) {
        nodes { requestedReviewer { ... on User { login } ... on Team { slug organization { login } } } }
      }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """

    /// The individual check runs and the exact per-state breakdown for one PR's head commit. Split out of
    /// `PRFields` because computing this - even just the breakdown, without listing the checks - is real work for
    /// GitHub when a commit has hundreds of check runs, unlike the single rollup `state` above (the same cheap
    /// field GitHub itself uses for the dot next to a commit everywhere else). So this is fetched lazily, one PR
    /// at a time, only when its detail view is shown.
    static let checksFragment = """
    fragment PRCheckNodes on PullRequest {
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
    query($owner: String!, $name: String!, $first: Int!, $after: String, $needsReviewers: Boolean!) {
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
    query($q: String!, $first: Int!, $after: String, $needsReviewers: Boolean!) {
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
        var mergeable: String?
        var reviewDecision: String?
        var author: Login?
        var repository: Repository
        var autoMergeRequest: Present?
        var viewerLatestReview: Review?
        var comments: Count
        var labels: Nodes<Label>
        var reviewRequests: Count
        /// Absent from the bulk list query unless `$needsReviewers` is true (only the inbox's review-requested
        /// search needs the actual names, to split direct requests from team ones).
        var reviewRequestNodes: Nodes<Request>?
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
        /// `state` is all the bulk list query asks for; `contexts` is only present in `ChecksQuery`'s response.
        struct Rollup: Decodable, Sendable { var state: String?; var contexts: Contexts? }
        struct Contexts: Decodable, Sendable {
            var nodes: [Context?]?
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

    /// Maps raw check/status-context nodes into `CheckRun`s. Shared by the bulk list decode (which usually has
    /// none, since the list query doesn't fetch them) and `ChecksQuery`'s lazy per-PR fetch.
    static func mapChecks(_ nodes: [Node.Context?]) -> [CheckRun] {
        nodes.compactMap { c in
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
    }

    /// Maps raw review-request nodes into logins and teams. Shared by the bulk list decode (which usually has
    /// none, since only the inbox's review-requested search asks for them) and `ReviewersQuery`'s lazy fetch.
    static func mapReviewRequests(_ nodes: [Node.Request?], fallbackOrg: String) -> (reviewers: [String], teams: [ReviewTeam]) {
        let reviewers = nodes.compactMap { $0?.requestedReviewer?.login }
        let teams = nodes.compactMap { r -> ReviewTeam? in
            guard let t = r?.requestedReviewer, let slug = t.slug else { return nil }
            return ReviewTeam(org: t.organization?.login ?? fallbackOrg, slug: slug)
        }
        return (reviewers, teams)
    }

    /// GitHub's own per-state totals are exact; counting the fetched checks is only a fallback for when they are
    /// missing. Only `ChecksQuery`'s lazy fetch ever has `contexts` to pass here.
    static func mapCheckCounts(_ contexts: Node.Contexts?, checks: [CheckRun]) -> CheckCounts {
        guard let runs = contexts?.checkRunCountsByState, let statuses = contexts?.statusContextCountsByState else {
            return CheckCounts(checks: checks)
        }
        return CheckCounts(checkRuns: runs.map { .init(state: $0.state, count: $0.count) },
                           statuses: statuses.map { .init(state: $0.state, count: $0.count) })
    }

    static func map(_ n: Node) -> PR? {
        guard let number = n.number else { return nil } // search can return non-PR nodes as {}
        let repo = RepoId(owner: n.repository.owner.login, name: n.repository.name)
        let reviewRequests = mapReviewRequests(n.reviewRequestNodes?.nodes ?? [], fallbackOrg: repo.owner)
        // The bulk query only asks for the rollup's own combined state, not a breakdown: see `checksFragment`.
        let checkSummary = statusContext(n.commits.nodes.first??.commit.statusCheckRollup?.state)
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
            mergeable: MergeableState(graphQL: n.mergeable),
            requestedReviewers: reviewRequests.reviewers,
            labels: n.labels.nodes.compactMap { $0 }.map { PRLabel(name: $0.name, color: $0.color) },
            checks: [],
            checkSummary: checkSummary,
            checkCounts: CheckCounts(),
            requestedTeams: reviewRequests.teams,
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

    /// GitHub's own response time for a page scales with its size - measured roughly linearly, and for `search`
    /// (every destination except a single repo) steeply enough that 30 on a big, busy scope (a large org, or an
    /// account with a lot of open PRs) regularly ran past what GitHub's gateway will wait for and came back as a
    /// 502. Smaller pages trade more "Load more" clicks for actually finishing.
    public static let defaultPageSize = 15

    // MARK: API

    public static func fetchRepo(_ repo: RepoId, first: Int = defaultPageSize, after: String? = nil, needsReviewers: Bool = false,
                                 client: GraphQLClient) async throws -> Page {
        let r: RepoResponse = try await client.query(repoPRs, variables: [
            "owner": repo.owner, "name": repo.name, "first": first, "after": after, "needsReviewers": needsReviewers,
        ])
        guard let conn = r.repository?.pullRequests else { throw GraphQLError(messages: ["repository not found: \(repo.fullName)"]) }
        return page(conn, rateLimit: r.rateLimit)
    }

    /// `scope` is e.g. "org:acme" or "author:octocat". `needsReviewers` fetches each PR's actual requested
    /// reviewers, not just the count - only the inbox's review-requested search needs it, to tell a direct
    /// request from a team one; everything else gets that lazily when a PR's detail view opens.
    public static func fetchSearch(scope: String, first: Int = defaultPageSize, after: String? = nil, needsReviewers: Bool = false,
                                   client: GraphQLClient) async throws -> Page {
        let r: SearchResponse = try await client.query(searchPRs, variables: [
            "q": searchPrefix + scope, "first": first, "after": after, "needsReviewers": needsReviewers,
        ])
        return page(r.search, rateLimit: r.rateLimit)
    }
}
