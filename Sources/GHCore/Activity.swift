import Foundation

public enum ReviewState: String, Sendable, Hashable {
    case approved, changesRequested, commented, dismissed, pending

    init(graphQL: String) {
        switch graphQL {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "DISMISSED": self = .dismissed
        case "PENDING": self = .pending
        default: self = .commented
        }
    }
}

public struct ActivityItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case comment, review(ReviewState) }
    public var id: String
    public var author: String
    public var date: Date
    public var body: String
    public var url: String?
    public var kind: Kind
}

public struct ThreadComment: Identifiable, Hashable, Sendable {
    public var id: String
    public var author: String
    public var date: Date
    public var body: String
    public var url: String?
}

/// An inline code-review conversation anchored to a file and line.
public struct ReviewThread: Identifiable, Hashable, Sendable {
    public var id: String
    public var path: String
    public var line: Int?
    public var isResolved: Bool
    public var isOutdated: Bool
    public var comments: [ThreadComment]
}

public struct PRActivity: Sendable, Equatable {
    public var description: String
    public var author: String
    public var createdAt: Date
    /// Issue comments and reviews with content, oldest first.
    public var items: [ActivityItem]
    public var threads: [ReviewThread]
    /// True when GitHub had more than we fetched (100 comments or reviews, 50 threads).
    public var truncated: Bool
    /// The rate limit as reported with this query, for the usage log.
    public var rateLimit: RateLimit?
}

public enum ActivityQuery {
    public static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      rateLimit { remaining limit cost resetAt used nodeCount }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          body createdAt author { login }
          comments(first: 100) { pageInfo { hasNextPage endCursor } nodes { id author { login } createdAt body url } }
          reviews(first: 100) { pageInfo { hasNextPage endCursor } nodes { id author { login } state submittedAt body url } }
          reviewThreads(first: 50) {
            pageInfo { hasNextPage endCursor }
            nodes { id path line isResolved isOutdated comments(first: 30) { pageInfo { hasNextPage endCursor } nodes { id author { login } createdAt body url } } }
          }
        }
      }
    }
    """

    struct Response: Decodable, Sendable {
        var rateLimit: RateLimit
        var repository: Repo?
        struct Repo: Decodable, Sendable { var pullRequest: PR? }
        struct PR: Decodable, Sendable {
            var body: String
            var createdAt: Date
            var author: Login?
            var comments: Conn<Comment>
            var reviews: Conn<Review>
            var reviewThreads: Conn<Thread>
        }
        struct Login: Decodable, Sendable { var login: String }
        struct Conn<T: Decodable & Sendable>: Decodable, Sendable {
            var pageInfo: Info?
            var nodes: [T?]

            /// Appends a later page; the combined connection continues where that page stopped.
            mutating func append(_ page: Conn<T>) {
                nodes += page.nodes
                pageInfo = page.pageInfo
            }
        }
        struct Info: Decodable, Sendable { var hasNextPage: Bool; var endCursor: String? }
        struct Comment: Decodable, Sendable {
            var id: String; var author: Login?; var createdAt: Date; var body: String; var url: String?
        }
        struct Review: Decodable, Sendable {
            var id: String; var author: Login?; var state: String; var submittedAt: Date?; var body: String; var url: String?
        }
        struct Thread: Decodable, Sendable {
            var id: String; var path: String; var line: Int?; var isResolved: Bool; var isOutdated: Bool
            var comments: Conn<Comment>
        }
    }

    static func map(_ r: Response.PR, rateLimit: RateLimit? = nil) -> PRActivity {
        var items: [ActivityItem] = r.comments.nodes.compactMap { $0 }.map {
            ActivityItem(id: $0.id, author: $0.author?.login ?? "ghost", date: $0.createdAt, body: $0.body, url: $0.url, kind: .comment)
        }
        for rev in r.reviews.nodes.compactMap({ $0 }) {
            let state = ReviewState(graphQL: rev.state)
            // Pending reviews are drafts. A body-less COMMENTED review only wraps inline threads, shown separately.
            guard state != .pending, let date = rev.submittedAt else { continue }
            if state == .commented && rev.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            items.append(ActivityItem(id: rev.id, author: rev.author?.login ?? "ghost", date: date, body: rev.body, url: rev.url, kind: .review(state)))
        }
        items.sort { $0.date < $1.date }
        let threads = r.reviewThreads.nodes.compactMap { $0 }.map { t in
            ReviewThread(id: t.id, path: t.path, line: t.line, isResolved: t.isResolved, isOutdated: t.isOutdated,
                         comments: t.comments.nodes.compactMap { $0 }.map {
                ThreadComment(id: $0.id, author: $0.author?.login ?? "ghost", date: $0.createdAt, body: $0.body, url: $0.url)
            })
        }
        let truncated = [r.comments.pageInfo?.hasNextPage, r.reviews.pageInfo?.hasNextPage, r.reviewThreads.pageInfo?.hasNextPage]
            .contains(true) || r.reviewThreads.nodes.contains { $0?.comments.pageInfo?.hasNextPage == true }
        return PRActivity(description: r.body, author: r.author?.login ?? "ghost", createdAt: r.createdAt,
                          items: items, threads: threads, truncated: truncated, rateLimit: rateLimit)
    }

    // MARK: Later pages

    /// Pages fetched per connection before we give up and report the conversation as truncated.
    static let maxExtraPages = 20

    private static let commentFields = "id author { login } createdAt body url"

    private static func connectionQuery(_ field: String, fields: String) -> String {
        """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) { pullRequest(number: $number) {
            \(field)(first: \(field == "reviewThreads" ? 50 : 100), after: $after) { pageInfo { hasNextPage endCursor } nodes { \(fields) } }
          } }
        }
        """
    }

    static let moreComments = connectionQuery("comments", fields: commentFields)
    static let moreReviews = connectionQuery("reviews", fields: "id author { login } state submittedAt body url")
    static let moreThreads = connectionQuery(
        "reviewThreads",
        fields: "id path line isResolved isOutdated comments(first: 30) { pageInfo { hasNextPage endCursor } nodes { \(commentFields) } }")
    static let moreReplies = """
    query($id: ID!, $after: String) {
      node(id: $id) { ... on PullRequestReviewThread {
        comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { \(commentFields) } }
      } }
    }
    """

    private struct MoreResponse<C: Decodable & Sendable>: Decodable, Sendable {
        var repository: Repo?
        struct Repo: Decodable, Sendable { var pullRequest: PullRequest? }
        struct PullRequest: Decodable, Sendable {
            var comments: C?
            var reviews: C?
            var reviewThreads: C?
        }
    }
    private struct RepliesResponse: Decodable, Sendable {
        var node: Node?
        struct Node: Decodable, Sendable { var comments: Response.Conn<Response.Comment>? }
    }

    /// Follows `after` cursors until the connection is exhausted or `maxExtraPages` is reached.
    private static func exhaust<T: Decodable & Sendable>(
        _ conn: Response.Conn<T>, client: GraphQLClient,
        page: @Sendable (String) async throws -> Response.Conn<T>?
    ) async throws -> Response.Conn<T> {
        var conn = conn
        var pages = 0
        while conn.pageInfo?.hasNextPage == true, let cursor = conn.pageInfo?.endCursor, pages < maxExtraPages {
            guard let next = try await page(cursor) else { break }
            conn.append(next)
            pages += 1
        }
        return conn
    }

    /// The first page of everything comes with the main query; this fetches the rest, including replies beyond
    /// a thread's first 30, so a long conversation (or a comment just posted at its end) is not silently cut.
    static func complete(_ pr: Response.PR, id: PrId, client: GraphQLClient) async throws -> Response.PR {
        @Sendable func vars(_ after: String) -> [String: Any?] {
            ["owner": id.repo.owner, "name": id.repo.name, "number": id.number, "after": after]
        }
        var pr = pr
        let firstComments = pr.comments, firstReviews = pr.reviews, firstThreads = pr.reviewThreads
        async let comments = exhaust(firstComments, client: client) { after in
            let r: MoreResponse<Response.Conn<Response.Comment>> = try await client.query(moreComments, variables: vars(after))
            return r.repository?.pullRequest?.comments
        }
        async let reviews = exhaust(firstReviews, client: client) { after in
            let r: MoreResponse<Response.Conn<Response.Review>> = try await client.query(moreReviews, variables: vars(after))
            return r.repository?.pullRequest?.reviews
        }
        async let threads = exhaust(firstThreads, client: client) { after in
            let r: MoreResponse<Response.Conn<Response.Thread>> = try await client.query(moreThreads, variables: vars(after))
            return r.repository?.pullRequest?.reviewThreads
        }
        pr.comments = try await comments
        pr.reviews = try await reviews
        pr.reviewThreads = try await threads

        // Replies beyond each thread's first 30.
        var nodes = pr.reviewThreads.nodes
        try await withThrowingTaskGroup(of: (Int, Response.Conn<Response.Comment>).self) { group in
            for (i, thread) in nodes.enumerated() {
                guard let thread, thread.comments.pageInfo?.hasNextPage == true else { continue }
                group.addTask {
                    let full = try await exhaust(thread.comments, client: client) { after in
                        let r: RepliesResponse = try await client.query(moreReplies, variables: ["id": thread.id, "after": after])
                        return r.node?.comments
                    }
                    return (i, full)
                }
            }
            for try await (i, full) in group { nodes[i]?.comments = full }
        }
        pr.reviewThreads.nodes = nodes
        return pr
    }

    public static func fetch(_ id: PrId, client: GraphQLClient) async throws -> PRActivity {
        let r: Response = try await client.query(query, variables: [
            "owner": id.repo.owner, "name": id.repo.name, "number": id.number,
        ])
        guard let pr = r.repository?.pullRequest else { throw GraphQLError(messages: ["PR not found: \(id.repo.fullName)#\(id.number)"]) }
        return map(try await complete(pr, id: id, client: client), rateLimit: r.rateLimit)
    }
}

public extension PrActions {
    /// Posts a top-level comment on the PR.
    func postComment(_ body: String, on pr: PR) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await comment(trimmed, on: pr)
    }
}
