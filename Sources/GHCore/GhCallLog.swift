import Foundation

/// One `gh` invocation the app made, and how it ended.
public struct GhCall: Identifiable, Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case ok
        case failed(status: Int32, stderr: String)
        case cancelled
    }

    public let id = UUID()
    public var date: Date
    public var duration: TimeInterval
    /// One line: what was asked, e.g. `graphql search q=is:pr is:open org:acme first=30`.
    public var summary: String
    /// The start of the GraphQL query text, when there was one.
    public var detail: String?
    public var outcome: Outcome
    public var bytes: Int

    public var failed: Bool { if case .failed = outcome { true } else { false } }

    /// Plain text for pasting into a bug report.
    public var text: String {
        let time = Self.clock.string(from: date)
        let state: String
        switch outcome {
        case .ok: state = "OK    "
        case .failed: state = "FAIL  "
        case .cancelled: state = "CANCEL"
        }
        var out = "\(time) \(state) \(String(format: "%5.1fs", duration)) \(summary)"
        if case .failed(let status, let stderr) = outcome { out += "\n    exit \(status): \(stderr)" }
        if failed, let detail { out += "\n    query: \(detail)" }
        return out
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()
}

/// Newest-first record of the `gh` calls this session, capped so it cannot grow without bound.
public final class GhCallLog: @unchecked Sendable {
    public static let capacity = 500

    private let lock = NSLock()
    private var calls: [GhCall] = []
    private var listener: (@Sendable ([GhCall]) -> Void)?

    public init() {}

    public var entries: [GhCall] { lock.withLock { calls } }

    /// Called after every change with the full list. May run on any thread.
    public func onChange(_ listener: @escaping @Sendable ([GhCall]) -> Void) {
        lock.withLock { self.listener = listener }
    }

    public func record(_ call: GhCall) {
        let (snapshot, listener) = lock.withLock { () -> ([GhCall], (@Sendable ([GhCall]) -> Void)?) in
            calls.insert(call, at: 0)
            if calls.count > Self.capacity { calls.removeLast(calls.count - Self.capacity) }
            return (calls, self.listener)
        }
        listener?(snapshot)
    }

    public func clear() {
        let listener = lock.withLock { () -> (@Sendable ([GhCall]) -> Void)? in calls = []; return self.listener }
        listener?([])
    }
}

/// Wraps a runner and records every call it makes, whether it succeeds, fails or is cancelled.
public struct LoggingGh: GhRunner {
    public let base: any GhRunner
    public let log: GhCallLog

    public init(_ base: any GhRunner, log: GhCallLog) { self.base = base; self.log = log }

    public func run(_ args: [String], stdin: Data?, cwd: URL?) async throws -> Data {
        let start = Date(), clock = ContinuousClock.now
        func seconds() -> TimeInterval {
            let d = ContinuousClock.now - clock
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
        let (summary, detail) = Self.describe(args)
        do {
            let data = try await base.run(args, stdin: stdin, cwd: cwd)
            log.record(GhCall(date: start, duration: seconds(), summary: summary, detail: detail, outcome: .ok, bytes: data.count))
            return data
        } catch {
            let outcome: GhCall.Outcome
            if error is CancellationError { outcome = .cancelled }
            else if let err = error as? GhError {
                outcome = .failed(status: err.status, stderr: Self.clip(err.stderr.trimmingCharacters(in: .whitespacesAndNewlines), 300))
            } else { outcome = .failed(status: -1, stderr: Self.clip("\(error)", 300)) }
            log.record(GhCall(date: start, duration: seconds(), summary: summary, detail: detail, outcome: outcome, bytes: 0))
            throw error
        }
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > n ? String(flat.prefix(n)) + "..." : flat
    }

    /// Top-level fields worth naming in a one-line summary of a GraphQL query.
    private static let hints = ["search", "repository", "organization", "repositoryOwner", "viewer", "user", "nodes", "node"]

    /// A one-line summary plus, for GraphQL, the start of the query. Variables are kept (they name the scope being
    /// fetched) but each is clipped; the query text is never stored whole. Tokens are never passed as arguments.
    static func describe(_ args: [String]) -> (summary: String, detail: String?) {
        var query: String?
        var rest: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if (a == "-f" || a == "-F" || a == "--raw-field" || a == "--field"), i + 1 < args.count {
                let pair = args[i + 1]
                if pair.hasPrefix("query=") { query = String(pair.dropFirst("query=".count)) }
                else { rest.append(clip(pair, 80)) }
                i += 2
            } else { rest.append(clip(a, 80)); i += 1 }
        }
        guard args.count >= 2, args[0] == "api", args[1] == "graphql", let query else {
            return (clip(rest.joined(separator: " "), 220), nil)
        }
        let body = query.drop { $0 != "{" }
        let hint = hints.compactMap { name -> (Int, String)? in
            body.range(of: name + "(").map { (body.distance(from: body.startIndex, to: $0.lowerBound), name) }
        }.min { $0.0 < $1.0 }?.1
        let searches = query.components(separatedBy: "search(").count - 1
        let label = searches > 1 ? "\(searches) searches" : (hint ?? "query")
        let vars = rest.filter { !$0.hasPrefix("api") && $0 != "graphql" }
        return (clip("graphql \(label) " + vars.joined(separator: " "), 260), clip(query, 200))
    }
}

/// Facts about how the app reaches GitHub that matter when a request fails only inside the app.
public enum GhDiagnostics {
    /// The `gh` the app found, and the names (never values) of proxy and certificate variables in its environment.
    public static func summary() -> String {
        let env = ProcessInfo.processInfo.environment
        let names = env.keys.filter { k in
            let u = k.uppercased()
            return ["PROXY", "SSL_CERT", "CA_BUNDLE", "NODE_EXTRA", "CURL_CA"].contains { u.contains($0) } || u.hasPrefix("GH_")
        }.sorted()
        let path = GhCLI.locate()?.path ?? "not found"
        return "gh: \(path)\nenvironment: " + (names.isEmpty ? "no proxy, certificate or GH_ variables" : names.joined(separator: ", "))
    }
}
