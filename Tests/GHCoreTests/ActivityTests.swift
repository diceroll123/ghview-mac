import Foundation
import Testing
@testable import GHCore

@Test func decodesRealActivityFixture() async throws {
    let data = try fixture("activity")
    let a = try await ActivityQuery.fetch(PrId(repo: RepoId(owner: "diceroll123", name: "ghview"), number: 42),
                                          client: GraphQLClient(gh: MockGh { _ in data }))
    #expect(a.items.count == 3)
    #expect(a.items.allSatisfy { $0.kind == .comment })
    #expect(a.items == a.items.sorted { $0.date < $1.date })
    #expect(!a.author.isEmpty)
    #expect(!a.truncated)
}

@Test func mapsReviewsAndThreads() async throws {
    let json = """
    {"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"repository":{"pullRequest":{
      "body":"desc","createdAt":"2026-01-01T00:00:00Z","author":null,
      "comments":{"pageInfo":{"hasNextPage":false},"nodes":[
        {"id":"c1","author":{"login":"bob"},"createdAt":"2026-01-03T00:00:00Z","body":"later","url":"u1"}]},
      "reviews":{"pageInfo":{"hasNextPage":true},"nodes":[
        {"id":"r1","author":{"login":"amy"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z","body":"","url":"u2"},
        {"id":"r2","author":{"login":"amy"},"state":"COMMENTED","submittedAt":"2026-01-02T01:00:00Z","body":"  ","url":null},
        {"id":"r3","author":{"login":"amy"},"state":"PENDING","submittedAt":null,"body":"draft","url":null},
        {"id":"r4","author":{"login":"cy"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-02T02:00:00Z","body":"fix it","url":null}]},
      "reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
        {"id":"t1","path":"a.swift","line":null,"isResolved":true,"isOutdated":true,"comments":{"nodes":[
          {"id":"tc1","author":null,"createdAt":"2026-01-02T01:00:00Z","body":"nit","url":null}]}}]}
    }}}}
    """
    let a = try await ActivityQuery.fetch(PrId(repo: RepoId(owner: "o", name: "r"), number: 1),
                                          client: GraphQLClient(gh: MockGh { _ in Data(json.utf8) }))
    #expect(a.author == "ghost")
    // empty COMMENTED wrapper and PENDING draft are dropped; the rest sorts by date
    #expect(a.items.map(\.id) == ["r1", "r4", "c1"])
    #expect(a.items.map(\.kind) == [.review(.approved), .review(.changesRequested), .comment])
    #expect(a.truncated)
    #expect(a.threads.count == 1 && a.threads[0].isResolved && a.threads[0].isOutdated && a.threads[0].line == nil)
    #expect(a.threads[0].comments[0].author == "ghost")
}

@Test func postsTrimmedCommentOrNothing() async throws {
    let seen = LockedBox<[[String]]>([])
    let actions = PrActions(gh: MockGh { args in seen.update { $0 += [args] }; return Data() })
    try await actions.postComment("   \n ", on: samplePR(5))
    #expect(seen.get().isEmpty)
    try await actions.postComment("  hello \n", on: samplePR(5))
    #expect(seen.get() == [["pr", "comment", "5", "-R", "o/r", "--body", "hello"]])
}

// MARK: long conversations

private func comment(_ i: Int) -> String {
    #"{"id":"c\#(i)","author":{"login":"u"},"createdAt":"2026-01-01T\#(String(format: "%02d", i / 3600 % 24)):\#(String(format: "%02d", i / 60 % 60)):\#(String(format: "%02d", i % 60))Z","body":"b\#(i)","url":null}"#
}

private func activityJSON(comments: [Int], commentsNext: String?, threadReplies: [Int], repliesNext: String?) -> String {
    func info(_ next: String?) -> String { #"{"hasNextPage":\#(next != nil),"endCursor":\#(next.map { "\"\($0)\"" } ?? "null")}"# }
    return """
    {"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"repository":{"pullRequest":{
      "body":"d","createdAt":"2026-01-01T00:00:00Z","author":{"login":"u"},
      "comments":{"pageInfo":\(info(commentsNext)),"nodes":[\(comments.map(comment).joined(separator: ","))]},
      "reviews":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
      "reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
        {"id":"t1","path":"a.swift","line":3,"isResolved":false,"isOutdated":false,
         "comments":{"pageInfo":\(info(repliesNext)),"nodes":[\(threadReplies.map(comment).joined(separator: ","))]}}]}
    }}}}
    """
}

@Test func aThreadWithThirtyOneRepliesShowsAllOfThem() async throws {
    let calls = LockedBox<[String]>([])
    let gh = MockGh { args in
        let q = args.first { $0.hasPrefix("query=") } ?? ""
        if q.contains("node(id:") {
            let after = args.first { $0.hasPrefix("after=") } ?? "-"
            calls.update { $0 += [after] }
            return Data(#"{"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(comment(31))]}}}}"#.utf8)
        }
        return Data(activityJSON(comments: [1], commentsNext: nil, threadReplies: Array(1...30), repliesNext: "R30").utf8)
    }
    let a = try await ActivityQuery.fetch(PrId(repo: RepoId(owner: "o", name: "r"), number: 1), client: GraphQLClient(gh: gh))
    #expect(a.threads[0].comments.count == 31)
    #expect(a.threads[0].comments.last?.id == "c31")
    #expect(calls.get() == ["after=R30"])
    #expect(!a.truncated)
}

@Test func commentsPastTheFirstHundredAreFetchedSoANewestPostIsVisible() async throws {
    let gh = MockGh { args in
        let q = args.first { $0.hasPrefix("query=") } ?? ""
        if q.contains("comments(first: 100, after: $after)") {
            #expect(args.contains("after=C100"))
            return Data(#"{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(comment(101))]}}}}}"#.utf8)
        }
        return Data(activityJSON(comments: Array(1...100), commentsNext: "C100", threadReplies: [1], repliesNext: nil).utf8)
    }
    let a = try await ActivityQuery.fetch(PrId(repo: RepoId(owner: "o", name: "r"), number: 1), client: GraphQLClient(gh: gh))
    #expect(a.items.count == 101)
    #expect(a.items.last?.id == "c101")
    #expect(!a.truncated)
}

@Test func anEndlessConversationStopsAtThePageCapAndSaysTruncated() async throws {
    let pages = LockedBox<Int>(0)
    let gh = MockGh { args in
        let q = args.first { $0.hasPrefix("query=") } ?? ""
        if q.contains("comments(first: 100, after: $after)") {
            pages.update { $0 += 1 }
            return Data(#"{"data":{"repository":{"pullRequest":{"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"more"},"nodes":[\#(comment(pages.get() + 1))]}}}}}"#.utf8)
        }
        return Data(activityJSON(comments: [1], commentsNext: "first", threadReplies: [1], repliesNext: nil).utf8)
    }
    let a = try await ActivityQuery.fetch(PrId(repo: RepoId(owner: "o", name: "r"), number: 1), client: GraphQLClient(gh: gh))
    #expect(pages.get() == ActivityQuery.maxExtraPages)
    #expect(a.truncated)
}
