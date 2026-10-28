import Foundation
import Testing
@testable import GHCore

@Test func chunksStayUnderTheLimitAndCoverEverySourceOnce() {
    let sources = (0..<60).map { Source.org("organization-\($0)") }
    let chunks = SearchScope.chunks(of: sources)
    #expect(chunks.count > 1)
    for c in chunks { #expect((PullRequestQuery.searchPrefix + c).count <= SearchScope.maxQueryLength) }
    let tokens = chunks.flatMap { $0.split(separator: " ").map(String.init) }
    #expect(tokens == sources.map(\.searchScope))  // every source, once, in order
    #expect(SearchScope.chunks(of: []).isEmpty)
    #expect(SearchScope.chunks(of: [.user("me"), .org("acme")]) == ["user:me org:acme"])
    // a tiny budget never drops a source, it just gives each its own chunk
    #expect(
        SearchScope.chunks(of: sources.prefix(3).map { $0 }, maxLength: 5) == [
            "org:organization-0", "org:organization-1", "org:organization-2",
        ])
}

private func node(_ n: Int, owner: String, created: String) -> String {
    """
    {"number":\(n),"title":"t\(n)","isDraft":false,"state":"OPEN","createdAt":"\(created)","updatedAt":"\(created)",
     "url":"https://x/\(n)","headRefName":"h","baseRefName":"main","headRefOid":"abc","additions":1,"deletions":1,
     "mergeable":"MERGEABLE","reviewDecision":null,"author":{"login":"a"},
     "repository":{"name":"r","owner":{"login":"\(owner)"}},"autoMergeRequest":null,"viewerLatestReview":null,
     "comments":{"totalCount":0},"labels":{"nodes":[]},"reviewRequests":{"totalCount":0},"commits":{"nodes":[]}}
    """
}
private func page(_ nodes: [String], next: String?) -> Data {
    Data(
        """
        {"data":{"rateLimit":{"remaining":9,"limit":10,"cost":1,"resetAt":null},
          "search":{"pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(next.map { "\"\($0)\"" } ?? "null")},"nodes":[\(nodes.joined(separator: ","))]}}}
        """.utf8)
}

@Test func pagerFetchesEveryChunkThenOnlyThoseWithMore() async throws {
    let seen = LockedBox<[String]>([])
    let gh = MockGh { args in
        let q = args.first { $0.hasPrefix("q=") } ?? ""
        let after = args.first { $0.hasPrefix("after=") } ?? "-"
        seen.update { $0 += ["\(q)|\(after)"] }
        switch (q.contains("org:a"), after) {
        case (true, "-"):
            return page(
                [node(1, owner: "a", created: "2026-01-01T00:00:00Z"), node(2, owner: "a", created: "2026-01-05T00:00:00Z")], next: "A1")
        case (true, "after=A1"): return page([node(3, owner: "a", created: "2026-01-03T00:00:00Z")], next: nil)
        default: return page([node(10, owner: "b", created: "2026-01-04T00:00:00Z")], next: nil)
        }
    }
    let client = GraphQLClient(gh: gh)
    var pager = CombinedPager(scopes: ["org:a", "org:b"])
    #expect(pager.hasMore && pager.pending == [0, 1])

    let first = try await CombinedPRs.fetchNext(pager, existing: [], client: client)
    #expect(first.prs.map(\.number) == [2, 10, 1])  // newest first across both chunks
    #expect(first.rateLimits.count == 2)
    pager = first.pager
    #expect(pager.hasMore && pager.pending == [0])  // only chunk a has another page

    seen.set([])
    let second = try await CombinedPRs.fetchNext(pager, existing: first.prs, client: client)
    #expect(seen.get().count == 1 && seen.get()[0].contains("org:a") && seen.get()[0].hasSuffix("after=A1"))
    #expect(second.prs.map(\.number) == [2, 10, 3, 1])  // merged into the existing list
    #expect(!second.pager.hasMore)
}

@Test func mergeDeduplicatesPreferringIncoming() throws {
    func pr(_ n: Int, _ title: String, _ created: TimeInterval) -> PR {
        var p = samplePR(n); p.title = title; p.createdAt = Date(timeIntervalSince1970: created); return p
    }
    let merged = CombinedPager.merge([pr(1, "old", 10), pr(2, "keep", 20)], [pr(1, "new", 10), pr(3, "fresh", 30)])
    #expect(merged.map(\.number) == [3, 2, 1])
    #expect(merged.first { $0.number == 1 }?.title == "new")
}

@Test func aFailingChunkDoesNotHideTheHealthyOnes() async throws {
    let broken = LockedBox<Bool>(true)
    let gh = MockGh { args in
        let q = args.first { $0.hasPrefix("q=") } ?? ""
        if q.contains("org:bad"), broken.get() { throw GhError(args: args, status: 1, stderr: "SSO required for org:bad") }
        return page(
            [node(q.contains("org:bad") ? 2 : 1, owner: q.contains("org:bad") ? "bad" : "ok", created: "2026-01-01T00:00:00Z")], next: nil)
    }
    let client = GraphQLClient(gh: gh)
    let first = try await CombinedPRs.fetchNext(CombinedPager(scopes: ["org:ok", "org:bad"]), existing: [], client: client)
    #expect(first.prs.map(\.number) == [1])  // the healthy source is usable
    #expect(first.failures == [.init(scope: "org:bad", message: "SSO required for org:bad")])
    #expect(first.pager.hasMore && first.pager.pending == [1])  // only the failed one waits for a retry

    // Retrying only the failed portion leaves the healthy chunk alone and keeps what was already loaded.
    let seen = LockedBox<[String]>([])
    let counting = MockGh { args in
        let q = args.first { $0.hasPrefix("q=") } ?? ""
        seen.update { $0 += [q] }
        return page([node(2, owner: "bad", created: "2026-01-02T00:00:00Z")], next: nil)
    }
    broken.set(false)
    let second = try await CombinedPRs.fetchNext(first.pager, existing: first.prs, onlyFailed: true, client: GraphQLClient(gh: counting))
    #expect(seen.get().count == 1 && seen.get()[0].contains("org:bad"))
    #expect(second.prs.map(\.number) == [2, 1])
    #expect(second.failures.isEmpty && !second.pager.hasMore)
}

@Test func whenEverySourceFailsTheFetchThrows() async {
    let gh = MockGh { args in throw GhError(args: args, status: 1, stderr: "boom") }
    await #expect(throws: GhError.self) {
        _ = try await CombinedPRs.fetchNext(CombinedPager(scopes: ["org:a", "org:b"]), existing: [], client: GraphQLClient(gh: gh))
    }
}

// MARK: GitHub's 1,000 result ceiling

private func pageWithTotal(_ nodes: [String], total: Int, next: String?) -> Data {
    Data(
        """
        {"data":{"rateLimit":{"remaining":9,"limit":10,"cost":1,"resetAt":null},
          "search":{"issueCount":\(total),"pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(next.map { "\"\($0)\"" } ?? "null")},"nodes":[\(nodes.joined(separator: ","))]}}}
        """.utf8)
}

private func range(in args: [String]) -> (lo: Date, hi: Date)? {
    guard let q = args.first(where: { $0.hasPrefix("q=") }), let r = q.range(of: "created:") else { return nil }
    let parts = q[r.upperBound...].split(separator: " ")[0].components(separatedBy: "..")
    guard parts.count == 2, let lo = ISO8601DateFormatter.plain.date(from: parts[0]),
        let hi = ISO8601DateFormatter.plain.date(from: parts[1])
    else { return nil }
    return (lo, hi)
}

@Test func anOversizedScopeIsSplitIntoDateSlicesThatCoverEverythingOnce() async throws {
    // 3,000 PRs spread evenly over 2018-2025.
    let start = ISO8601DateFormatter.plain.date(from: "2018-01-01T00:00:00Z")!.timeIntervalSince1970
    let end = ISO8601DateFormatter.plain.date(from: "2026-01-01T00:00:00Z")!.timeIntervalSince1970
    let counter = LockedBox<Int>(0)
    let gh = MockGh { args in
        counter.update { $0 += 1 }
        let n = counter.get()
        guard let r = range(in: args) else {
            return pageWithTotal([node(n, owner: "big", created: "2026-01-01T00:00:00Z")], total: 3000, next: "C1")
        }
        let overlap = max(0, min(r.hi.timeIntervalSince1970, end) - max(r.lo.timeIntervalSince1970, start))
        let total = Int((3000 * overlap / (end - start)).rounded())
        return pageWithTotal(total > 0 ? [node(n, owner: "big", created: "2020-01-01T00:00:00Z")] : [], total: total, next: nil)
    }
    let first = try await CombinedPRs.fetchNext(CombinedPager(scopes: ["org:big"]), existing: [], client: GraphQLClient(gh: gh))

    let slices = first.pager.chunks
    #expect(slices.count >= 3 && slices.count <= 16)
    #expect(slices.allSatisfy { $0.isSlice && ($0.total ?? 0) <= SearchPartition.ceiling && !$0.started })
    #expect(abs(slices.reduce(0) { $0 + ($1.total ?? 0) } - 3000) <= slices.count)
    #expect(first.pager.hasMore)

    // Newest first, and each slice starts exactly one second after the next-older one ends: no overlap, no gap.
    let ranges = slices.map { range(in: ["q=" + $0.scope])! }
    for (newer, older) in zip(ranges, ranges.dropFirst()) {
        #expect(older.hi.addingTimeInterval(1) == newer.lo)
    }
    #expect(ranges.first!.hi > ISO8601DateFormatter.plain.date(from: "2026-01-01T00:00:00Z")!)
}

@Test func aSliceThatCannotBeSplitFurtherIsReportedIncomplete() async throws {
    // 2,000 PRs created in the very same second: no date range separates them.
    let instant = ISO8601DateFormatter.plain.date(from: "2024-05-05T12:00:00Z")!
    let gh = MockGh { args in
        guard let r = range(in: args) else {
            return pageWithTotal([node(1, owner: "big", created: "2024-05-05T12:00:00Z")], total: 2000, next: "C1")
        }
        let inside = r.lo <= instant && instant <= r.hi
        // GitHub stops paging at 1,000, so a full slice delivers its first results and then reports no next page.
        return pageWithTotal(inside ? [node(2, owner: "big", created: "2024-05-05T12:00:00Z")] : [], total: inside ? 2000 : 0, next: nil)
    }
    let client = GraphQLClient(gh: gh)
    let first = try await CombinedPRs.fetchNext(CombinedPager(scopes: ["org:big"]), existing: [], client: client)
    #expect(first.pager.chunks.count == 1)
    #expect(!first.pager.isIncomplete)  // nothing fetched from the slice yet

    let second = try await CombinedPRs.fetchNext(first.pager, existing: first.prs, client: client)
    #expect(!second.pager.hasMore)
    #expect(second.pager.isIncomplete)
    #expect(second.pager.totalMatches == 2000 && second.pager.receivedMatches == 1)
}

@Test func aSearchUnderTheCeilingIsNeverSplitOrIncomplete() async throws {
    let gh = MockGh { _ in pageWithTotal([node(1, owner: "a", created: "2026-01-01T00:00:00Z")], total: 1, next: nil) }
    let result = try await CombinedPRs.fetchNext(CombinedPager(scopes: ["org:a"]), existing: [], client: GraphQLClient(gh: gh))
    #expect(result.pager.chunks.count == 1 && !result.pager.chunks[0].isSlice)
    #expect(!result.pager.isIncomplete)
}

@Test func aBrokenSourceInsideAPackedChunkIsIsolatedFromTheOthers() async throws {
    let queries = LockedBox<[String]>([])
    let gh = MockGh { args in
        let q = args.first { $0.hasPrefix("q=") } ?? ""
        queries.update { $0 += [q] }
        if q.contains("org:bad") { throw GhError(args: args, status: 1, stderr: "SAML enforcement") }
        let n = q.contains("org:ok1") ? 1 : 2
        return page([node(n, owner: "o", created: "2026-01-0\(n)T00:00:00Z")], next: nil)
    }
    // One search packs all three sources, so the whole chunk fails first and is then tried source by source.
    let packed = CombinedPager(scopes: ["org:ok1 org:bad org:ok2"])
    let result = try await CombinedPRs.fetchNext(packed, existing: [], client: GraphQLClient(gh: gh))
    #expect(result.prs.map(\.number).sorted() == [1, 2])
    #expect(result.failures == [.init(scope: "org:bad", message: "SAML enforcement")])
    #expect(result.pager.chunks.map(\.scope) == ["org:ok1", "org:bad", "org:ok2"])
    #expect(queries.get().count == 4)  // the packed search, then one per source
}

@Test func aUsersQueryIsNeverSplitIntoItsQualifiersAfterAFailure() async throws {
    let queries = LockedBox<[String]>([])
    let gh = MockGh { args in
        let q = args.first { $0.hasPrefix("q=") } ?? ""
        queries.update { $0 += [q] }
        throw GhError(args: args, status: 1, stderr: "Validation Failed")
    }
    // `a AND b` must not degrade to `a`, then `b`, whose union is a different (larger) result.
    await #expect(throws: GhError.self) {
        _ = try await CombinedPRs.fetchNext(
            CombinedPager(scopes: ["author:@me label:bug"], explodable: false), existing: [], client: GraphQLClient(gh: gh))
    }
    #expect(queries.get().count == 1 && queries.get()[0].hasSuffix("author:@me label:bug"))
}
