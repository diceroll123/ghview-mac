import Foundation

/// Fetches one PR's individual check runs and their exact per-state breakdown. The bulk list query only carries
/// the rollup's single combined state (`PullRequestQuery`'s `checkSummary`), so this is called lazily, one PR at
/// a time, when its detail view opens.
public enum ChecksQuery {
    static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      rateLimit { remaining limit cost resetAt used nodeCount }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { ...PRCheckNodes }
      }
    }
    \(PullRequestQuery.checksFragment)
    """

    struct Response: Decodable, Sendable {
        var rateLimit: RateLimit
        var repository: Repo?
        struct Repo: Decodable, Sendable { var pullRequest: PR? }
        struct PR: Decodable, Sendable { var commits: PullRequestQuery.Node.Nodes<PullRequestQuery.Node.CommitNode> }
    }

    public static func fetch(_ id: PrId, client: GraphQLClient) async throws
        -> (checks: [CheckRun], counts: CheckCounts, rateLimit: RateLimit) {
        let r: Response = try await client.query(query, variables: [
            "owner": id.repo.owner, "name": id.repo.name, "number": id.number,
        ])
        guard let pr = r.repository?.pullRequest else {
            throw GraphQLError(messages: ["PR not found: \(id.repo.fullName)#\(id.number)"])
        }
        let contexts = pr.commits.nodes.first??.commit.statusCheckRollup?.contexts
        let checks = PullRequestQuery.mapChecks(contexts?.nodes ?? [])
        let counts = PullRequestQuery.mapCheckCounts(contexts, checks: checks)
        return (checks, counts, r.rateLimit)
    }
}
