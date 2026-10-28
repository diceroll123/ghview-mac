import Foundation

/// What is waiting in one source: all open PRs, and how many of them ask for the viewer's review.
public struct SourceCounts: Codable, Sendable, Equatable {
    public var open: Int
    public var reviewRequested: Int
    /// Set when GitHub refused this source's search, typically an org that needs SAML SSO authorization.
    public var error: String?

    public init(open: Int = 0, reviewRequested: Int = 0, error: String? = nil) {
        self.open = open
        self.reviewRequested = reviewRequested
        self.error = error
    }

    public var needsSSO: Bool { error?.localizedCaseInsensitiveContains("SAML") == true }
}

public enum SourceCountsQuery {
    /// Sources per request (so up to twice as many aliased searches). The rate-limit cost is 1 point whatever the
    /// size, but GitHub's own gateway can 502 a request that packs in too many searches at once - kept small, and
    /// batches run concurrently (see `fetch`), so a big catalog is still fast without risking that.
    static let batchSize = 15

    /// Two aliased searches per source: `o<i>` for open PRs and `r<i>` for review requests.
    static func build(_ sources: [Source]) -> String {
        var parts = ["rateLimit { remaining limit cost resetAt used nodeCount }"]
        for (i, s) in sources.enumerated() {
            parts.append("o\(i): search(query: \"is:pr is:open \(s.searchScope)\", type: ISSUE, first: 1) { issueCount }")
            parts.append(
                "r\(i): search(query: \"is:pr is:open review-requested:@me \(s.searchScope)\", type: ISSUE, first: 1) { issueCount }")
        }
        return "query {\n  " + parts.joined(separator: "\n  ") + "\n}"
    }

    struct Response: Decodable, Sendable {
        var rateLimit: RateLimit?
        var counts: [String: Int?]

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        private struct Count: Decodable { var issueCount: Int }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            rateLimit = try c.decodeIfPresent(RateLimit.self, forKey: Key(stringValue: "rateLimit")!)
            var out: [String: Int?] = [:]
            for key in c.allKeys where key.stringValue != "rateLimit" {
                // a failed alias comes back as null
                out[key.stringValue] = try c.decodeIfPresent(Count.self, forKey: key)?.issueCount
            }
            counts = out
        }
    }

    static func assemble(_ sources: [Source], _ response: Response, errors: [GraphQLErrorInfo]) -> [String: SourceCounts] {
        var result: [String: SourceCounts] = [:]
        for (i, s) in sources.enumerated() {
            let failure = errors.first { $0.path.first == "o\(i)" || $0.path.first == "r\(i)" }
            let open = response.counts["o\(i)"] ?? nil, requested = response.counts["r\(i)"] ?? nil
            result[s.id] = SourceCounts(open: open ?? 0, reviewRequested: requested ?? 0, error: failure?.message)
        }
        return result
    }

    /// Fetches counts for every source, one small batch of aliased searches at a time, all in flight together
    /// (`GhRunner` bounds how many `gh` calls actually run at once). Sources whose own search fails get `error`
    /// set instead of failing their batch; a batch that fails outright (a 502, say) is simply missing from the
    /// result rather than failing every other batch too - the caller keeps last-known counts for those sources.
    public static func fetch(_ sources: [Source], client: GraphQLClient) async
        -> (counts: [String: SourceCounts], rateLimits: [RateLimit])
    {
        let batches = stride(from: 0, to: sources.count, by: batchSize).map {
            Array(sources[$0..<min($0 + batchSize, sources.count)])
        }
        var all: [String: SourceCounts] = [:]
        var limits: [RateLimit] = []
        await withTaskGroup(of: (counts: [String: SourceCounts], rateLimit: RateLimit?)?.self) { group in
            for batch in batches {
                group.addTask {
                    guard
                        let (response, errors): (Response, [GraphQLErrorInfo]) =
                            try? await client.queryAllowingErrors(build(batch))
                    else { return nil }
                    return (assemble(batch, response, errors: errors), response.rateLimit)
                }
            }
            for await result in group {
                guard let result else { continue }
                all.merge(result.counts) { $1 }
                if let rl = result.rateLimit { limits.append(rl) }
            }
        }
        return (all, limits)
    }
}

/// Last known counts on disk so badges show instantly on launch, before the network answers.
public enum SourceCountsCache {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ghview-mac/source-counts.json")
    }

    /// The cache file for one account, next to the legacy shared one.
    public static func url(for scope: AccountScope, beside url: URL = defaultURL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(scope.countsFileName)
    }

    public static func load(from url: URL = defaultURL) -> [String: SourceCounts] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: SourceCounts].self, from: data)) ?? [:]
    }

    public static func save(_ counts: [String: SourceCounts], to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(counts) { try? data.write(to: url, options: .atomic) }
    }
}
