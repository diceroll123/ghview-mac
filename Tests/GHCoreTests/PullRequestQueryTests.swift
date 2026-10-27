import Foundation
import Testing
@testable import GHCore

struct MockGh: GhRunner {
    var respond: @Sendable ([String]) throws -> Data
    func run(_ args: [String], stdin: Data?, cwd: URL?) async throws -> Data { try respond(args) }
}

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Test func decodesRepoPRFixture() async throws {
    let data = try fixture("repo_prs")
    let seen = LockedBox<[String]>([])
    let gh = MockGh { args in seen.set(args); return data }
    let page = try await PullRequestQuery.fetchRepo(RepoId(owner: "diceroll123", name: "ghview"),
                                                    client: GraphQLClient(gh: gh))
    #expect(!page.prs.isEmpty)
    #expect(page.rateLimit.cost == 1)
    let first = try #require(page.prs.first)
    #expect(first.id.repo.fullName == "diceroll123/ghview")
    #expect(first.headSha.count == 40)
    #expect(seen.get().prefix(3) == ["api", "graphql", "-f"])
}

@Test func checkAggregation() {
    #expect(CheckStatus.aggregate([]) == .unknown)
    #expect(CheckStatus.aggregate([.passing, .passing]) == .passing)
    #expect(CheckStatus.aggregate([.passing, .pending]) == .pending)
    #expect(CheckStatus.aggregate([.pending, .cancelled]) == .cancelled)
    #expect(CheckStatus.aggregate([.cancelled, .failing, .pending]) == .failing)
    #expect(CheckStatus.aggregate([.passing, .unknown]) == .unknown)
}

@Test func checkRunMapping() {
    #expect(PullRequestQuery.checkStatus(status: "COMPLETED", conclusion: "SUCCESS") == .passing)
    #expect(PullRequestQuery.checkStatus(status: "COMPLETED", conclusion: "TIMED_OUT") == .failing)
    #expect(PullRequestQuery.checkStatus(status: "IN_PROGRESS", conclusion: nil) == .pending)
    #expect(PullRequestQuery.checkStatus(status: "COMPLETED", conclusion: "CANCELLED") == .cancelled)
    #expect(PullRequestQuery.statusContext("ERROR") == .failing)
}

@Test func graphQLErrorsSurface() throws {
    let body = Data(#"{"errors":[{"message":"boom"}]}"#.utf8)
    #expect(throws: GraphQLError.self) {
        let _: PullRequestQuery.SearchResponse = try GraphQLClient.decode(body, as: PullRequestQuery.SearchResponse.self)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    /// Read-modify-write under the lock; `set(get() + x)` loses updates when requests run concurrently.
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
}

@Test func reviewRequestsKeepTeamsSeparateAndReportTotals() async throws {
    var json = try #require(JSONSerialization.jsonObject(with: fixture("repo_prs")) as? [String: Any])
    var data = json["data"] as! [String: Any]
    var repo = data["repository"] as! [String: Any]
    var prs = repo["pullRequests"] as! [String: Any]
    var nodes = prs["nodes"] as! [[String: Any]]
    nodes[0]["reviewRequests"] = ["totalCount": 30, "nodes": [
        ["requestedReviewer": ["login": "alice"]],
        ["requestedReviewer": ["slug": "alice", "organization": ["login": "acme"]]],
    ]]
    nodes[0]["labels"] = ["totalCount": 25, "nodes": [["name": "bug", "color": "ff0000"]]]
    prs["nodes"] = nodes; repo["pullRequests"] = prs; data["repository"] = repo; json["data"] = data
    let body = try JSONSerialization.data(withJSONObject: json)
    let page = try await PullRequestQuery.fetchRepo(RepoId(owner: "o", name: "r"), client: GraphQLClient(gh: MockGh { _ in body }))
    let pr = page.prs[0]
    #expect(pr.requestedReviewers == ["alice"])
    #expect(pr.requestedTeams == [ReviewTeam(org: "acme", slug: "alice")])
    #expect(pr.reviewRequestTotal == 30 && pr.reviewersTruncated)
    #expect(pr.labelTotal == 25 && pr.labelsTruncated)
}
