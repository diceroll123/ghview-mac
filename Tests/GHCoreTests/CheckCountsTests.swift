import Foundation
import Testing
@testable import GHCore

/// Lifts one PR's `commits` block out of the recorded list fixture and feeds it to `ChecksQuery.fetch`, the
/// lazy per-PR call that now carries the full breakdown and the individual check runs.
private func fetchChecks(prNumber: Int, mutate: (inout [String: Any]) -> Void = { _ in }) async throws
    -> (checks: [CheckRun], counts: CheckCounts) {
    let json = try #require(JSONSerialization.jsonObject(with: fixture("repo_prs_checks")) as? [String: Any])
    let data = json["data"] as! [String: Any]
    let repo = data["repository"] as! [String: Any]
    let prs = repo["pullRequests"] as! [String: Any]
    let nodes = prs["nodes"] as! [[String: Any]]
    var pr = try #require(nodes.first { $0["number"] as? Int == prNumber })
    var commits = pr["commits"] as! [String: Any]
    var cnodes = commits["nodes"] as! [[String: Any]]
    var commit = cnodes[0]["commit"] as! [String: Any]
    var rollup = commit["statusCheckRollup"] as! [String: Any]
    var contexts = rollup["contexts"] as! [String: Any]
    mutate(&contexts)
    rollup["contexts"] = contexts; commit["statusCheckRollup"] = rollup
    cnodes[0]["commit"] = commit; commits["nodes"] = cnodes; pr["commits"] = commits
    let body: [String: Any] = ["data": ["rateLimit": data["rateLimit"]!, "repository": ["pullRequest": ["commits": pr["commits"]!]]]]
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    let id = PrId(repo: RepoId(owner: "diceroll123", name: "pymermaider"), number: prNumber)
    let (checks, counts, _) = try await ChecksQuery.fetch(id, client: GraphQLClient(gh: MockGh { _ in bodyData }))
    return (checks, counts)
}

// MARK: real data

@Test func realFixtureBreaksDownThirtyTwoTwo() async throws {
    let failing = try await fetchChecks(prNumber: 522)
    #expect(failing.counts == CheckCounts(passed: 30, failed: 2, skipped: 2))
    #expect(failing.counts.total == 34 && failing.counts.done == 34)
    #expect(failing.counts.summary == "30 passed, 2 failed, 2 skipped")
    #expect(failing.checks.count == 34 && failing.checks.filter { $0.status == .skipped }.count == 2)
    #expect(failing.counts.status == .failing)

    let clean = try await fetchChecks(prNumber: 540)
    #expect(clean.counts == CheckCounts(passed: 33, skipped: 1))
    #expect(clean.counts.status == .passing)        // a skipped check does not stop a PR from passing
}

@Test func countsComeFromGitHubTotalsBeyondTheFetchedChecks() async throws {
    let result = try await fetchChecks(prNumber: 522) { ctx in
        ctx["checkRunCountsByState"] = [["state": "SUCCESS", "count": 150], ["state": "FAILURE", "count": 3],
                                        ["state": "IN_PROGRESS", "count": 7]]
    }
    #expect(result.counts == CheckCounts(passed: 150, failed: 3, pending: 7))
    #expect(result.checks.count == 34)                 // the list is still limited to what was fetched
}

/// The bulk list query no longer asks for `contexts` at all, only the rollup's own combined `state`: this is
/// what GitHub sends back for that.
@Test func bulkListOnlyCarriesTheRollupsCombinedState() async throws {
    func pr(state: String?) async throws -> PR {
        let body = Data("""
        {"data":{"rateLimit":{"remaining":9,"limit":10,"cost":1,"resetAt":null},
          "repository":{"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
            {"number":1,"title":"t","isDraft":false,"state":"OPEN","createdAt":"2026-01-01T00:00:00Z",
             "updatedAt":"2026-01-01T00:00:00Z","url":"https://x/1","headRefName":"h","baseRefName":"main",
             "headRefOid":"abc","additions":1,"deletions":1,"mergeable":"MERGEABLE","reviewDecision":null,
             "author":{"login":"a"},"repository":{"name":"r","owner":{"login":"o"}},"autoMergeRequest":null,
             "viewerLatestReview":null,"comments":{"totalCount":0},"labels":{"nodes":[]},
             "reviewRequests":{"totalCount":0},
             "commits":{"nodes":[{"commit":{"statusCheckRollup":\(state.map { #"{"state":"\#($0)"}"# } ?? "null")}}]}}
          ]}}}}
        """.utf8)
        let page = try await PullRequestQuery.fetchRepo(RepoId(owner: "o", name: "r"), client: GraphQLClient(gh: MockGh { _ in body }))
        return try #require(page.prs.first)
    }
    let failing = try await pr(state: "FAILURE")
    #expect(failing.checks.isEmpty && failing.checkCounts.isEmpty)
    #expect(failing.checkSummary == .failing)

    #expect(try await pr(state: "SUCCESS").checkSummary == .passing)
    #expect(try await pr(state: "PENDING").checkSummary == .pending)
    #expect(try await pr(state: nil).checkSummary == .unknown)          // no commit status at all: no checks
}

@Test func fallsBackToTheFetchedChecksWhenTotalsAreMissing() async throws {
    let result = try await fetchChecks(prNumber: 522) { ctx in
        ctx.removeValue(forKey: "checkRunCountsByState"); ctx.removeValue(forKey: "statusContextCountsByState")
    }
    #expect(result.counts == CheckCounts(passed: 30, failed: 2, skipped: 2))
}

// MARK: state mapping

@Test func checkRunStatesMapToSegments() {
    let table: [(String, CheckCounts.Kind)] = [
        ("SUCCESS", .passed),
        ("FAILURE", .failed), ("TIMED_OUT", .failed), ("STARTUP_FAILURE", .failed), ("ACTION_REQUIRED", .failed),
        ("CANCELLED", .cancelled),
        ("SKIPPED", .skipped), ("NEUTRAL", .skipped), ("STALE", .skipped), ("COMPLETED", .skipped),
        ("IN_PROGRESS", .pending), ("QUEUED", .pending), ("PENDING", .pending), ("WAITING", .pending),
        ("SOMETHING_GITHUB_ADDS_LATER", .skipped),     // unknown states are gray, never green
    ]
    for (state, kind) in table { #expect(CheckCounts.kind(checkRunState: state) == kind, "\(state)") }
}

@Test func statusStatesMapToSegments() {
    for (state, kind) in [("SUCCESS", CheckCounts.Kind.passed), ("FAILURE", .failed), ("ERROR", .failed),
                          ("PENDING", .pending), ("EXPECTED", .pending), ("NEW_STATE", .skipped)] {
        #expect(CheckCounts.kind(statusState: state) == kind, "\(state)")
    }
}

@Test func combinesCheckRunsAndStatusesAndIgnoresZeros() {
    let c = CheckCounts(checkRuns: [.init(state: "SUCCESS", count: 5), .init(state: "FAILURE", count: 0), .init(state: "SKIPPED", count: 1)],
                        statuses: [.init(state: "SUCCESS", count: 2), .init(state: "PENDING", count: 1)])
    #expect(c == CheckCounts(passed: 7, skipped: 1, pending: 1))
}

@Test func buildingFromChecksCountsEachStatus() {
    func run(_ s: CheckStatus) -> CheckRun { CheckRun(id: UUID().uuidString, name: "c", status: s) }
    let c = CheckCounts(checks: [.passing, .passing, .failing, .cancelled, .pending, .skipped, .unknown].map(run))
    #expect(c == CheckCounts(passed: 2, failed: 1, skipped: 2, cancelled: 1, pending: 1, unrecognized: 1))
}

// MARK: segments and summary

@Test func segmentsKeepBarOrderAndFractionsSumToOne() {
    let c = CheckCounts(passed: 30, failed: 2, skipped: 2, cancelled: 1, pending: 3)
    #expect(c.segments.map(\.kind) == [.passed, .failed, .skipped, .cancelled, .pending])
    #expect(abs(c.segments.map(\.fraction).reduce(0, +) - 1) < 1e-9)
    #expect(c.done == 35 && c.total == 38)
    #expect(c.summary == "30 passed, 2 failed, 2 skipped, 1 cancelled, 3 running")
}

@Test func emptyAndPendingOnlyCounts() {
    let none = CheckCounts()
    #expect(none.isEmpty && none.segments.isEmpty && none.summary == "" && none.done == 0)
    let running = CheckCounts(pending: 3)
    #expect(!running.isEmpty && running.done == 0 && running.segments.count == 1 && running.segments[0].fraction == 1)
}

// MARK: aggregate with skipped

@Test func skippedChecksNeverChangeTheOutcome() {
    #expect(CheckStatus.aggregate([.skipped]) == .passing)
    #expect(CheckStatus.aggregate([.passing, .skipped]) == .passing)
    #expect(CheckStatus.aggregate([.skipped, .failing]) == .failing)
    #expect(CheckStatus.aggregate([.skipped, .pending]) == .pending)
    #expect(CheckStatus.aggregate([.skipped, .unknown]) == .unknown)
    #expect(PullRequestQuery.checkStatus(status: "COMPLETED", conclusion: "SKIPPED") == .skipped)
    #expect(PullRequestQuery.checkStatus(status: "COMPLETED", conclusion: "NEUTRAL") == .skipped)
    #expect(PullRequestQuery.checkStatus(status: "COMPLETED", conclusion: "SUCCESS") == .passing)
}

@Test func checkCountsRoundTripThroughCodable() throws {
    let c = CheckCounts(passed: 4, failed: 1, skipped: 2, cancelled: 3, pending: 5)
    #expect(try JSONDecoder().decode(CheckCounts.self, from: JSONEncoder().encode(c)) == c)
}


// MARK: bar layout

@Test func layoutIsProportionalAndFillsTheBar() {
    let frames = CheckCounts(passed: 3, failed: 1).layout(width: 201, gap: 1)   // 200 usable: 150 + 50
    #expect(frames.map(\.kind) == [.passed, .failed])
    #expect(abs(frames[0].width - 150) < 1e-9 && abs(frames[1].width - 50) < 1e-9)
    #expect(frames[0].x == 0 && abs(frames[1].x - 151) < 1e-9)
    let last = frames[1]
    #expect(abs(last.x + last.width - 201) < 1e-9)                              // ends exactly at the bar's edge
}

@Test func aSingleFailureAmongManyStaysVisible() {
    let frames = CheckCounts(passed: 33, failed: 1).layout(width: 100, gap: 1.5, minSegment: 3)
    let failed = frames.first { $0.kind == .failed }!
    #expect(failed.width >= 3 - 1e-9)                       // proportionally it would be about 2.9pt
    let last = frames.last!
    #expect(abs(last.x + last.width - 100) < 1e-9)          // the room came out of the passed segment
    #expect(frames.allSatisfy { $0.width > 0 })
}

@Test func layoutEdgeCases() {
    #expect(CheckCounts().layout(width: 100).isEmpty)
    #expect(CheckCounts(passed: 2).layout(width: 0).isEmpty)
    let one = CheckCounts(passed: 5).layout(width: 80)
    #expect(one.count == 1 && one[0].x == 0 && abs(one[0].width - 80) < 1e-9)    // no gaps with one segment
    // too narrow for every segment to reach the minimum: equal shares, nothing overlaps or goes negative
    let tight = CheckCounts(passed: 20, failed: 1, skipped: 1, cancelled: 1, pending: 1).layout(width: 12, gap: 1, minSegment: 3)
    #expect(tight.count == 5 && tight.allSatisfy { $0.width > 0 })
    #expect(zip(tight, tight.dropFirst()).allSatisfy { $0.x + $0.width <= $1.x + 1e-9 })
}

@Test func layoutKeepsSegmentsInOrderWithoutOverlap() {
    let frames = CheckCounts(passed: 30, failed: 2, skipped: 2, cancelled: 1, pending: 3).layout(width: 300)
    #expect(frames.map(\.kind) == [.passed, .failed, .skipped, .cancelled, .pending])
    #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.x + $0.width < $1.x + 1e-9 })
    #expect(abs((frames.last!.x + frames.last!.width) - 300) < 1e-9)
}

@Test func summaryAgreesWithTotalsWhenTheFailureIsBeyondTheFetchedChecks() async throws {
    // The fetched checks are all green, but GitHub's totals say a check past the first page failed.
    let result = try await fetchChecks(prNumber: 540) { ctx in
        ctx["checkRunCountsByState"] = [["state": "SUCCESS", "count": 120], ["state": "FAILURE", "count": 1]]
        ctx["statusContextCountsByState"] = [] as [[String: Any]]
    }
    #expect(result.checks.allSatisfy { $0.status != .failing })
    #expect(result.counts.failed == 1)
    #expect(result.counts.status == .failing)
}

@Test func statusIsWorstFirstFromTheTotals() {
    #expect(CheckCounts(passed: 100, pending: 1).status == .pending)
    #expect(CheckCounts(passed: 100, cancelled: 1).status == .cancelled)
    #expect(CheckCounts(passed: 100, failed: 1, cancelled: 1, pending: 1).status == .failing)
    #expect(CheckCounts(passed: 3, skipped: 1).status == .passing)
    #expect(CheckCounts().status == .unknown)
}

@Test func anUnrecognizedStateIsNeverPassing() {
    let counts = CheckCounts(checkRuns: [.init(state: "SUCCESS", count: 5), .init(state: "BRAND_NEW", count: 1)], statuses: [])
    #expect(counts.status == .unknown)
    #expect(counts.skipped == 1)                    // still drawn gray
    #expect(CheckCounts(checkRuns: [.init(state: "NEUTRAL", count: 1), .init(state: "SUCCESS", count: 5)], statuses: []).status == .passing)
}
