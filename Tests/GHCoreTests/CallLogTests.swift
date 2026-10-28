import Foundation
import Testing
@testable import GHCore

private func logged(_ log: GhCallLog, _ respond: @escaping @Sendable ([String]) throws -> Data) -> LoggingGh {
    LoggingGh(MockGh(respond: respond), log: log)
}

@Test func recordsSuccessWithSummary() async throws {
    let log = GhCallLog()
    let gh = logged(log) { _ in Data("{}".utf8) }
    _ = try await gh.run([
        "api", "graphql", "-f", "query=query($q: String!) { rateLimit { cost } search(query: $q) { issueCount } }",
        "-f", "q=is:pr is:open org:acme", "-F", "first=30",
    ])
    let call = try #require(log.entries.first)
    #expect(call.outcome == .ok)
    #expect(call.bytes == 2)
    #expect(call.summary.hasPrefix("graphql search"))
    #expect(call.summary.contains("q=is:pr is:open org:acme"))
    #expect(call.summary.contains("first=30"))
    #expect(!call.summary.contains("rateLimit"))
    #expect(call.detail?.hasPrefix("query($q") == true)
}

@Test func recordsFailureAndRethrows() async throws {
    let log = GhCallLog()
    let gh = logged(log) { args in throw GhError(args: args, status: 1, stderr: "gh: HTTP 502\n") }
    await #expect(throws: GhError.self) { _ = try await gh.run(["api", "user/orgs"]) }
    let call = try #require(log.entries.first)
    #expect(call.outcome == .failed(status: 1, stderr: "gh: HTTP 502"))
    #expect(call.failed)
    #expect(call.summary == "api user/orgs")
    #expect(call.text.contains("exit 1: gh: HTTP 502"))
}

@Test func recordsCancellation() async throws {
    let log = GhCallLog()
    let gh = logged(log) { _ in throw CancellationError() }
    await #expect(throws: CancellationError.self) { _ = try await gh.run(["api", "rate_limit"]) }
    #expect(log.entries.first?.outcome == .cancelled)
}

@Test func logIsCappedNewestFirst() async throws {
    let log = GhCallLog()
    let gh = logged(log) { _ in Data() }
    for i in 0..<(GhCallLog.capacity + 5) { _ = try await gh.run(["api", "n\(i)"]) }
    #expect(log.entries.count == GhCallLog.capacity)
    #expect(log.entries.first?.summary == "api n\(GhCallLog.capacity + 4)")
}

@Test func longQueriesAndVariablesAreClipped() {
    let long = String(repeating: "x", count: 500)
    let (summary, detail) = LoggingGh.describe(["api", "graphql", "-f", "query={ viewer { login } } \(long)", "-f", "body=\(long)"])
    #expect(summary.count < 300)
    #expect((detail ?? "").count <= 203)
}

@Test func clearEmptiesLogAndNotifies() {
    let log = GhCallLog()
    let seen = LockedBox<Int>(-1)
    log.onChange { seen.set($0.count) }
    log.record(GhCall(date: Date(), duration: 0, summary: "a", detail: nil, outcome: .ok, bytes: 0))
    #expect(seen.get() == 1)
    log.clear()
    #expect(seen.get() == 0)
}
