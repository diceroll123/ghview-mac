import Foundation
import Testing
@testable import GHCore

@Test func parsesRealRateLimitFixture() throws {
    let buckets = try RateLimitAPI.parse(fixture("rate_limit"))
    #expect(buckets.prefix(3).map(\.name) == ["core", "graphql", "search"])
    #expect(buckets[0].limit == 5000 && buckets[0].title == "REST (core)")
    // unused extras are hidden, used ones would sort after the main three
    #expect(buckets.allSatisfy { ["core", "graphql", "search"].contains($0.name) || $0.used > 0 })
}

@Test func extraBucketsOnlyWhenUsed() throws {
    let json = """
    {"resources":{"core":{"limit":5000,"used":1,"remaining":4999,"reset":1},
      "search":{"limit":30,"used":0,"remaining":30,"reset":2},
      "graphql":{"limit":5000,"used":0,"remaining":5000,"reset":3},
      "code_search":{"limit":10,"used":4,"remaining":6,"reset":4},
      "scim":{"limit":15000,"used":0,"remaining":15000,"reset":5}}}
    """
    let buckets = try RateLimitAPI.parse(Data(json.utf8))
    #expect(buckets.map(\.name) == ["core", "graphql", "search", "code_search"])
    #expect(buckets[3].title == "Code search")
    #expect(abs(buckets[3].fractionUsed - 0.4) < 0.0001)
}

@Test func requestLogOrdersCapsAndTotals() {
    var log = RequestLog()
    func rl(_ cost: Int, _ remaining: Int) -> RateLimit {
        RateLimit(remaining: remaining, limit: 5000, cost: cost, resetAt: nil, used: nil, nodeCount: nil)
    }
    log.record("first", rl(1, 4999))
    log.record("second", rl(3, 4996))
    #expect(log.entries.map(\.label) == ["second", "first"])
    #expect(log.totalCost == 4 && log.count == 2)
    for i in 0..<150 { log.record("q\(i)", rl(1, 4000)) }
    #expect(log.entries.count == RequestLog.capacity)
    #expect(log.entries.first?.label == "q149")
    #expect(log.count == 152 && log.totalCost == 154) // totals keep counting past the cap
}

@Test func rateLimitHelpers() throws {
    let rl = try GraphQLClient.decoder.decode(RateLimit.self, from: Data(
        #"{"remaining":4000,"limit":5000,"cost":2,"resetAt":"2026-10-26T23:29:50Z","used":1000,"nodeCount":120}"#.utf8))
    #expect(rl.nodeCount == 120 && rl.used == 1000)
    #expect(abs(rl.fractionUsed - 0.2) < 0.0001)
    #expect(rl.resetDate == Date(timeIntervalSince1970: 1793057390))
    // older fixtures without the new fields still decode
    let old = try GraphQLClient.decoder.decode(RateLimit.self, from: Data(#"{"remaining":1,"limit":2,"cost":1,"resetAt":null}"#.utf8))
    #expect(old.used == nil && old.resetDate == nil)
}
