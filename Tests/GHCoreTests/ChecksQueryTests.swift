import Foundation
import Testing
@testable import GHCore

/// Builds a `ChecksQuery` response by lifting one PR's `commits` block out of the list fixture, since both
/// queries share the same `commits { nodes { commit { statusCheckRollup ... } } }` shape.
private func checksResponse(prNumber: Int) throws -> Data {
    let json = try #require(JSONSerialization.jsonObject(with: fixture("repo_prs_checks")) as? [String: Any])
    let data = json["data"] as! [String: Any]
    let repo = data["repository"] as! [String: Any]
    let prs = repo["pullRequests"] as! [String: Any]
    let nodes = prs["nodes"] as! [[String: Any]]
    let pr = try #require(nodes.first { $0["number"] as? Int == prNumber })
    let body: [String: Any] = [
        "data": [
            "rateLimit": data["rateLimit"]!,
            "repository": ["pullRequest": ["commits": pr["commits"]!]],
        ],
    ]
    return try JSONSerialization.data(withJSONObject: body)
}

@Test func checksQueryFetchesTheIndividualRunsForOnePR() async throws {
    let data = try checksResponse(prNumber: 522)
    let id = PrId(repo: RepoId(owner: "diceroll123", name: "pymermaider"), number: 522)
    let (checks, rateLimit) = try await ChecksQuery.fetch(id, client: GraphQLClient(gh: MockGh { _ in data }))
    #expect(checks.count == 34)
    #expect(checks.filter { $0.status == .failing }.count == 2)
    #expect(rateLimit.cost == 1)
}

@Test func checksQueryThrowsWhenThePRIsMissing() async throws {
    let body = Data(#"{"data":{"rateLimit":{"remaining":1,"limit":1,"cost":1,"resetAt":"2026-01-01T00:00:00Z","used":0,"nodeCount":0},"repository":{"pullRequest":null}}}"#.utf8)
    let id = PrId(repo: RepoId(owner: "o", name: "r"), number: 1)
    await #expect(throws: GraphQLError.self) {
        _ = try await ChecksQuery.fetch(id, client: GraphQLClient(gh: MockGh { _ in body }))
    }
}
