import Foundation
import Testing
@testable import GHCore

@Test func buildsTwoAliasedSearchesPerSource() {
    let q = SourceCountsQuery.build([.user("me"), .org("acme")])
    #expect(q.contains(#"o0: search(query: "is:pr is:open user:me""#))
    #expect(q.contains(#"r0: search(query: "is:pr is:open review-requested:@me user:me""#))
    #expect(q.contains(#"o1: search(query: "is:pr is:open org:acme""#))
    #expect(q.contains("rateLimit"))
}

@Test func decodesRealCountsFixture() async throws {
    let data = try fixture("source_counts")
    let sources: [Source] = [.user("diceroll123"), .org("rneopets")]
    let (counts, limits) = try await SourceCountsQuery.fetch(sources, client: GraphQLClient(gh: MockGh { _ in data }))
    #expect(counts["diceroll123"]?.open ?? 0 > 0)
    #expect(counts["rneopets"]?.open ?? 0 > 0)
    #expect(counts.values.allSatisfy { $0.error == nil })
    #expect(limits.count == 1 && limits[0].cost == 1)
}

@Test func partialFailureMarksOnlyThatSource() async throws {
    // Real `gh` output for a query where one alias failed: exit 1, data and errors both on stdout.
    let body = Data(#"""
    {"data":{"rateLimit":{"remaining":10,"limit":5000,"cost":1,"resetAt":null},
             "o0":{"issueCount":4},"r0":{"issueCount":1},"o1":null,"r1":{"issueCount":0}},
     "errors":[{"type":"FORBIDDEN","path":["o1"],"message":"Resource protected by organization SAML enforcement."}]}
    """#.utf8)
    let gh = MockGh { args in throw GhError(args: args, status: 1, stderr: "gh: Resource protected", stdout: body) }
    let (counts, _) = try await SourceCountsQuery.fetch([.user("me"), .org("locked")], client: GraphQLClient(gh: gh))
    #expect(counts["me"] == SourceCounts(open: 4, reviewRequested: 1, error: nil))
    #expect(counts["locked"]?.error?.contains("SAML") == true && counts["locked"]?.needsSSO == true)
    #expect(counts["locked"]?.open == 0)
}

@Test func failureWithoutDataStillThrows() async {
    let gh = MockGh { args in throw GhError(args: args, status: 1, stderr: "gh: network down") }
    await #expect(throws: GhError.self) {
        _ = try await SourceCountsQuery.fetch([.user("me")], client: GraphQLClient(gh: gh))
    }
    let allErrors = MockGh { args in throw GhError(args: args, status: 1, stderr: "x", stdout: Data(#"{"errors":[{"message":"bad"}]}"#.utf8)) }
    await #expect(throws: GhError.self) { // no data at all: the original error surfaces
        _ = try await SourceCountsQuery.fetch([.user("me")], client: GraphQLClient(gh: allErrors))
    }
}

@Test func realPartialResponseFixtureDecodes() async throws {
    struct Out: Decodable, Sendable { var ok: Issues; var missing: Nothing?
        struct Issues: Decodable, Sendable { var issueCount: Int }
        struct Nothing: Decodable, Sendable { var id: String } }
    let data = try fixture("graphql_partial")
    let gh = MockGh { args in throw GhError(args: args, status: 1, stderr: "gh: Could not resolve", stdout: data) }
    let (out, errors): (Out, [GraphQLErrorInfo]) = try await GraphQLClient(gh: gh).queryAllowingErrors("query")
    #expect(out.ok.issueCount > 0 && out.missing == nil)
    #expect(errors.count == 1 && errors[0].path == ["missing"] && errors[0].type == "NOT_FOUND")
}

@Test func batchesLargeSourceLists() async throws {
    let sources = (0..<120).map { Source.org("org\($0)") }
    let calls = LockedBox<Int>(0)
    let gh = MockGh { _ in calls.update { $0 += 1 }; return Data(#"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null}}}"#.utf8) }
    let (counts, limits) = try await SourceCountsQuery.fetch(sources, client: GraphQLClient(gh: gh))
    #expect(calls.get() == 3 && limits.count == 3)          // 50 + 50 + 20
    #expect(counts.count == 120 && counts.values.allSatisfy { $0.open == 0 })
}

@Test func cacheRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ghview-\(UUID().uuidString)/counts.json")
    #expect(SourceCountsCache.load(from: url).isEmpty)
    let counts = ["acme": SourceCounts(open: 3, reviewRequested: 1), "locked": SourceCounts(error: "SAML")]
    SourceCountsCache.save(counts, to: url)
    #expect(SourceCountsCache.load(from: url) == counts)
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}
