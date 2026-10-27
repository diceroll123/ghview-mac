import Foundation

public struct RateLimit: Sendable, Equatable, Decodable {
    public var remaining: Int
    public var limit: Int
    public var cost: Int
    public var resetAt: String?
    /// Points spent in the current window, and nodes the last query could have returned (GraphQL's own accounting).
    public var used: Int?
    public var nodeCount: Int?

    public var resetDate: Date? { resetAt.flatMap { ISO8601DateFormatter.plain.date(from: $0) } }
    /// 0...1, how much of the window is spent.
    public var fractionUsed: Double { limit > 0 ? Double(limit - remaining) / Double(limit) : 0 }
}

public struct GraphQLError: Error, LocalizedError {
    public let messages: [String]
    public var errorDescription: String? { messages.joined(separator: "; ") }
}

/// One entry of a GraphQL response's `errors` array.
public struct GraphQLErrorInfo: Sendable, Equatable {
    public var message: String
    public var type: String?
    /// The response key it belongs to, e.g. the alias of a failed search.
    public var path: [String]
}

/// Thin wrapper over `gh api graphql`.
public struct GraphQLClient: Sendable {
    public let gh: any GhRunner
    public init(gh: any GhRunner) { self.gh = gh }

    private struct Envelope<T: Decodable>: Decodable {
        var data: T?
        var errors: [Err]?
        struct Err: Decodable {
            var message: String
            var type: String?
            var path: [PathItem]?
        }
        /// Path entries are strings (keys) or ints (list indices).
        struct PathItem: Decodable {
            var text: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { text = s } else { text = String(try c.decode(Int.self)) }
            }
        }
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.plain.date(from: s) { return date }
            if let date = ISO8601DateFormatter.fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    private func args(_ query: String, _ variables: [String: Any?]) -> [String] {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
            guard let value else { continue }
            if let i = value as? Int { args += ["-F", "\(key)=\(i)"] }
            else if let b = value as? Bool { args += ["-F", "\(key)=\(b)"] }
            else { args += ["-f", "\(key)=\(value)"] }
        }
        return args
    }

    /// Variables are passed as strings (`-f`) or typed ints/bools (`-F`, so GitHub sees a real number or boolean
    /// rather than the string "true"); nil values are omitted.
    /// Throws if GraphQL reports errors and returns no data.
    public func query<T: Decodable & Sendable>(_ query: String, variables: [String: Any?] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await gh.run(args(query, variables))
        return try Self.decode(data, as: type)
    }

    /// Like `query`, but a response with both data and errors is a success: the errors come back alongside.
    /// `gh` exits non-zero for those partial failures yet still prints the body, so it is recovered from the error.
    public func queryAllowingErrors<T: Decodable & Sendable>(
        _ query: String, variables: [String: Any?] = [:], as type: T.Type = T.self
    ) async throws -> (data: T, errors: [GraphQLErrorInfo]) {
        let body: Data
        do { body = try await gh.run(args(query, variables)) }
        catch let err as GhError {
            guard !err.stdout.isEmpty, (try? Self.decoder.decode(Envelope<T>.self, from: err.stdout))?.data != nil else { throw err }
            body = err.stdout
        }
        let env = try Self.decoder.decode(Envelope<T>.self, from: body)
        let errors = (env.errors ?? []).map { GraphQLErrorInfo(message: $0.message, type: $0.type, path: ($0.path ?? []).map(\.text)) }
        guard let payload = env.data else { throw GraphQLError(messages: errors.map(\.message)) }
        return (payload, errors)
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let env = try decoder.decode(Envelope<T>.self, from: data)
        if let errors = env.errors, !errors.isEmpty, env.data == nil {
            throw GraphQLError(messages: errors.map(\.message))
        }
        guard let payload = env.data else { throw GraphQLError(messages: ["empty response"]) }
        return payload
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
