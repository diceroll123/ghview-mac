import Foundation

/// Fetches one PR's actual requested reviewers and teams. The bulk list query only carries the cheap total count
/// (the inbox's review-requested search is the one exception, since it needs identity to tell a direct request
/// from a team one), so this is called lazily when a PR's detail view opens.
public enum ReviewersQuery {
    static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      rateLimit { remaining limit cost resetAt used nodeCount }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewRequests(first: 20) {
            nodes { requestedReviewer { ... on User { login } ... on Team { slug organization { login } } } }
          }
        }
      }
    }
    """

    struct Response: Decodable, Sendable {
        var rateLimit: RateLimit
        var repository: Repo?
        struct Repo: Decodable, Sendable { var pullRequest: PR? }
        struct PR: Decodable, Sendable { var reviewRequests: PullRequestQuery.Node.Nodes<PullRequestQuery.Node.Request> }
    }

    public static func fetch(_ id: PrId, client: GraphQLClient) async throws
        -> (reviewers: [String], teams: [ReviewTeam], rateLimit: RateLimit) {
        let r: Response = try await client.query(query, variables: [
            "owner": id.repo.owner, "name": id.repo.name, "number": id.number,
        ])
        guard let pr = r.repository?.pullRequest else {
            throw GraphQLError(messages: ["PR not found: \(id.repo.fullName)#\(id.number)"])
        }
        let mapped = PullRequestQuery.mapReviewRequests(pr.reviewRequests.nodes, fallbackOrg: id.repo.owner)
        return (mapped.reviewers, mapped.teams, r.rateLimit)
    }
}
