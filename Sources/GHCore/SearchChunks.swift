import Foundation

/// Packs several sources into search scopes that stay under GitHub's documented 256-character query limit.
/// (GraphQL search was observed to tolerate longer queries, but the documented limit is the safe contract.)
public enum SearchScope {
    public static let maxQueryLength = 256
    /// Room kept free for a ` created:<from>..<to>` qualifier, added when a scope has to be split by date.
    static let dateRangeReserve = 52

    /// Each returned scope is `org:a user:b ...`; GitHub ORs repeated owner qualifiers, so one chunk is one search.
    public static func chunks(of sources: [Source], prefix: String = PullRequestQuery.searchPrefix,
                              maxLength: Int = maxQueryLength) -> [String] {
        let budget = max(1, maxLength - prefix.count - dateRangeReserve)
        var out: [String] = [], current = ""
        for source in sources {
            let token = source.searchScope
            if current.isEmpty { current = token }
            else if current.count + 1 + token.count <= budget { current += " " + token }
            else { out.append(current); current = token }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Pagination across several searches at once. Each chunk has its own cursor; "load more" advances only the
/// chunks that still have pages, and results from all chunks are merged newest first.
public struct CombinedPager: Sendable, Equatable {
    public struct Chunk: Sendable, Equatable {
        public var id = UUID()
        public var scope: String
        public var cursor: String?
        public var hasNext: Bool
        public var started: Bool
        /// Matches GitHub reports for this scope, and how many we have received.
        public var total: Int?
        public var fetched = 0
        /// True once this chunk is a date slice produced by `SearchPartition`, which is never split again.
        public var isSlice = false
        /// Only a chunk that packs several sources may be split into them after a failure. A user's query may not:
        /// its qualifiers are ANDed, and trying them one by one would return the union instead.
        public var explodable = true
        /// Why the last attempt on this chunk failed; cleared by the next success. A failed chunk keeps its
        /// cursor, so it is retried from where it stopped.
        public var lastError: String?

        /// All pages are in but fewer results arrived than match: GitHub stops paging at 1,000.
        public var isIncomplete: Bool { started && !hasNext && (total ?? 0) > fetched }
    }

    public private(set) var chunks: [Chunk]

    public init(scopes: [String], explodable: Bool = true) {
        chunks = scopes.map { Chunk(scope: $0, cursor: nil, hasNext: false, started: false, explodable: explodable) }
    }

    /// Chunks that have not been fetched yet, or have another page.
    public var pending: [Int] { chunks.indices.filter { !chunks[$0].started || chunks[$0].hasNext } }
    public var hasMore: Bool { !pending.isEmpty }

    public struct Failure: Sendable, Equatable {
        public var scope: String
        public var message: String
        public init(scope: String, message: String) { self.scope = scope; self.message = message }
    }

    func index(of id: UUID) -> Int? { chunks.firstIndex { $0.id == id } }

    /// A chunk that packs several sources into one search: its sources, which can then be tried one by one.
    func sources(ofChunk i: Int) -> [String] {
        let c = chunks[i]
        return c.isSlice || c.started || !c.explodable ? [] : c.scope.split(separator: " ").map(String.init)
    }

    /// Replaces a multi-source chunk with one chunk per source, so a failing source cannot hold the others back.
    /// Returns the ids of the new chunks.
    mutating func explode(chunk i: Int) -> [UUID] {
        let parts = sources(ofChunk: i).map { Chunk(scope: $0, cursor: nil, hasNext: false, started: false) }
        guard parts.count > 1 else { return [] }
        chunks.replaceSubrange(i...i, with: parts)
        return parts.map(\.id)
    }

    mutating func setError(_ message: String?, chunk i: Int) { chunks[i].lastError = message }

    /// Chunks whose last attempt failed.
    public var failures: [Failure] { chunks.compactMap { c in c.lastError.map { Failure(scope: c.scope, message: $0) } } }

    /// Matches across all chunks, and how many of them have been received.
    public var totalMatches: Int { chunks.reduce(0) { $0 + ($1.total ?? 0) } }
    public var receivedMatches: Int { chunks.reduce(0) { $0 + $1.fetched } }
    /// True when GitHub's per-search limit means some matches cannot be reached with this query.
    public var isIncomplete: Bool { chunks.contains { $0.isIncomplete } }

    /// Replaces chunk `i` with date slices that each fit under the search limit, newest first.
    mutating func split(chunk i: Int, into slices: [(scope: String, total: Int)]) {
        let new = slices.map { Chunk(scope: $0.scope, cursor: nil, hasNext: false, started: false, total: $0.total, isSlice: true) }
        chunks.replaceSubrange(i...i, with: new)
    }

    mutating func apply(_ page: PullRequestQuery.Page, toChunk i: Int) {
        chunks[i].fetched += page.prs.count
        if let total = page.totalCount { chunks[i].total = total }
        chunks[i].started = true
        chunks[i].cursor = page.endCursor
        chunks[i].hasNext = page.hasNextPage
    }

    /// De-duplicates by PR (incoming wins, so refreshed data replaces stale) and sorts newest first.
    public static func merge(_ existing: [PR], _ incoming: [PR]) -> [PR] {
        var byID: [PrId: PR] = [:]
        for pr in existing { byID[pr.id] = pr }
        for pr in incoming { byID[pr.id] = pr }
        return byID.values.sorted { ($0.createdAt, $1.number) > ($1.createdAt, $0.number) }
    }
}

public enum CombinedPRs {
    public struct Result: Sendable {
        public var pager: CombinedPager
        public var prs: [PR]
        public var rateLimits: [RateLimit]
        /// Chunks that failed this time or earlier and are still waiting for a retry.
        public var failures: [CombinedPager.Failure] { pager.failures }
    }

    /// Fetches the next page of every pending chunk concurrently and merges it into `existing`.
    /// A chunk that fails is recorded on the pager and keeps its place for a retry while the others still
    /// deliver; the call throws only when every chunk it tried failed. `onlyFailed` retries just those, and
    /// `skipFailed` leaves them alone so a caller paging to the end does not hammer a broken source.
    public static func fetchNext(_ pager: CombinedPager, existing: [PR], first: Int = PullRequestQuery.defaultPageSize, onlyFailed: Bool = false,
                                 skipFailed: Bool = false, needsReviewers: Bool = false, client: GraphQLClient) async throws -> Result {
        var pager = pager
        var queue = pager.pending.filter {
            (!onlyFailed || pager.chunks[$0].lastError != nil) && (!skipFailed || pager.chunks[$0].lastError == nil)
        }.map { pager.chunks[$0].id }
        var pages: [(UUID, PullRequestQuery.Page)] = []
        var firstError: Error?
        // Round one tries every pending chunk. A multi-source chunk that fails is split into its sources and those
        // are tried in the next round, so only the source that is actually broken stays failed.
        while !queue.isEmpty {
            let round = queue.compactMap { id in pager.index(of: id).map { ($0, pager.chunks[$0]) } }
            queue = []
            let outcomes = await withTaskGroup(of: (UUID, Swift.Result<PullRequestQuery.Page, Error>).self) { group in
                for (_, chunk) in round {
                    group.addTask {
                        do {
                            return (chunk.id, .success(try await PullRequestQuery.fetchSearch(scope: chunk.scope, first: first, after: chunk.cursor, needsReviewers: needsReviewers, client: client)))
                        } catch { return (chunk.id, .failure(error)) }
                    }
                }
                var out: [(UUID, Swift.Result<PullRequestQuery.Page, Error>)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (id, outcome) in outcomes {
                guard let i = pager.index(of: id) else { continue }
                switch outcome {
                case .success(let page):
                    pages.append((id, page))
                    pager.setError(nil, chunk: i)
                    pager.apply(page, toChunk: i)
                case .failure(let error):
                    if error is CancellationError { throw error }
                    let split = pager.explode(chunk: i)
                    if split.isEmpty {
                        firstError = firstError ?? error
                        pager.setError((error as? LocalizedError)?.errorDescription ?? "\(error)", chunk: i)
                    } else { queue += split }
                }
            }
        }
        if pages.isEmpty, let firstError { throw firstError }
        // GitHub never pages past 1,000 results of one search, so a bigger scope is cut into date slices that
        // each fit. Looked up by id, because replacing a chunk shifts the indices after it.
        for (id, page) in pages where (page.totalCount ?? 0) > SearchPartition.ceiling {
            guard let i = pager.index(of: id), !pager.chunks[i].isSlice else { continue }
            // If slicing fails the chunk stays whole; it then simply reports the shortfall.
            guard let slices = try? await SearchPartition.split(scope: pager.chunks[i].scope, client: client) else { continue }
            pager.split(chunk: i, into: slices)
        }
        return Result(pager: pager, prs: CombinedPager.merge(existing, pages.flatMap { $0.1.prs }),
                      rateLimits: pages.map { $0.1.rateLimit })
    }
}

/// Cuts a search scope into non-overlapping `created:` ranges that each match at most `ceiling` PRs.
public enum SearchPartition {
    /// GitHub serves at most this many results for any one search, however far you page.
    public static let ceiling = 1000
    /// Ranges shorter than this are not cut further; a slice that is still too big stays incomplete.
    static let minimumSpan: TimeInterval = 3600
    static let earliest = Date(timeIntervalSince1970: 1_199_145_600) // 2008-01-01, before GitHub existed

    static func stamp(_ d: Date) -> String { ISO8601DateFormatter.plain.string(from: d) }

    /// Slices of `scope`, newest first, with the match count of each. Empty ranges are dropped.
    public static func split(scope: String, client: GraphQLClient, now: Date = Date()) async throws
        -> [(scope: String, total: Int)] {
        func walk(_ lo: Date, _ hi: Date) async throws -> [(scope: String, total: Int)] {
            let sliced = "\(scope) created:\(stamp(lo))..\(stamp(hi))"
            let total = try await PullRequestQuery.fetchSearch(scope: sliced, first: 1, client: client).totalCount ?? 0
            if total == 0 { return [] }
            if total <= ceiling || hi.timeIntervalSince(lo) <= minimumSpan { return [(sliced, total)] }
            let mid = Date(timeIntervalSince1970: ((lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2).rounded(.down))
            async let older = walk(lo, mid)
            async let newer = walk(mid.addingTimeInterval(1), hi)
            return try await newer + older
        }
        return try await walk(earliest, now)
    }
}
