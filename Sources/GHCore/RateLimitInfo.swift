import Foundation

/// One GitHub rate-limit bucket (core REST, search, ...).
public struct RateBucket: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var limit: Int
    public var used: Int
    public var remaining: Int
    public var resetAt: Date

    public var fractionUsed: Double { limit > 0 ? Double(limit - remaining) / Double(limit) : 0 }

    public var title: String {
        switch name {
        case "core": "REST (core)"
        case "graphql": "GraphQL"
        case "search": "Search"
        case "code_search": "Code search"
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public enum RateLimitAPI {
    struct Response: Decodable {
        var resources: [String: Raw]
        struct Raw: Decodable { var limit: Int; var used: Int; var remaining: Int; var reset: TimeInterval }
    }

    /// `gh api rate_limit` does not count against any quota. Buckets other than the three main ones are
    /// returned only if they have been used, and the list is ordered core, graphql, search, then the rest.
    public static func fetchBuckets(gh: any GhRunner) async throws -> [RateBucket] {
        let data = try await gh.run(["api", "rate_limit"])
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [RateBucket] {
        let resp = try JSONDecoder().decode(Response.self, from: data)
        let main = ["core", "graphql", "search"]
        let buckets = resp.resources.map {
            RateBucket(name: $0.key, limit: $0.value.limit, used: $0.value.used, remaining: $0.value.remaining,
                       resetAt: Date(timeIntervalSince1970: $0.value.reset))
        }
        return buckets
            .filter { main.contains($0.name) || $0.used > 0 }
            .sorted {
                let a = main.firstIndex(of: $0.name) ?? main.count, b = main.firstIndex(of: $1.name) ?? main.count
                return (a, $0.name) < (b, $1.name)
            }
    }
}

public struct RequestLogEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var date: Date
    public var label: String
    public var cost: Int
    public var remaining: Int
    public var nodeCount: Int?
}

/// What this session has spent, newest first, capped so it cannot grow without bound.
public struct RequestLog: Sendable, Equatable {
    public private(set) var entries: [RequestLogEntry] = []
    public private(set) var totalCost = 0
    public private(set) var count = 0
    public static let capacity = 100

    public init() {}

    public mutating func record(_ label: String, _ rl: RateLimit, at date: Date = Date()) {
        entries.insert(RequestLogEntry(date: date, label: label, cost: rl.cost, remaining: rl.remaining, nodeCount: rl.nodeCount), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        totalCost += rl.cost
        count += 1
    }
}
