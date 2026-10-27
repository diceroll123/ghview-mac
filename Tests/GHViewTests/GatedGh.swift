import Foundation
import Testing
@testable import GHCore

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isOpen: Bool { lock.withLock { value } }
    func set(_ v: Bool) { lock.withLock { value = v } }
}

/// A scripted `gh` whose responses are held until the test releases them, so tests can decide the order
/// in which concurrent requests finish. Requests are identified by a tag:
/// `repos:<owner>`, `prs:<owner>/<name>` or `search:<scope>`.
final class GatedGh: GhRunner, Sendable {
    private actor State {
        struct Waiter { var cont: CheckedContinuation<Void, Error> }
        var waiting: [String: [Waiter]] = [:]
        var arrivals: [String: Int] = [:]
        var log: [String] = []

        func arrive(_ tag: String) {
            arrivals[tag, default: 0] += 1
            log.append(tag)
        }
        func wait(_ tag: String) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiting[tag, default: []].append(Waiter(cont: c))
            }
        }
        func release(_ tag: String, error: Error?) {
            guard var list = waiting[tag], !list.isEmpty else { return }
            let w = list.removeFirst()
            waiting[tag] = list
            if let error { w.cont.resume(throwing: error) } else { w.cont.resume() }
        }
        func arrived(_ tag: String) -> Int { arrivals[tag] ?? 0 }
        func requests() -> [String] { log }
    }

    private let state = State()
    /// When false, a request answers at once (for the parts of a test that are not about ordering).
    private let gate: @Sendable (String) -> Bool
    private let open = OSAllocatedUnfairLockBox()

    /// Answers a request itself instead of with the canned data; return nil to fall through.
    private let override: @Sendable ([String]) throws -> Data?

    init(gate: @escaping @Sendable (String) -> Bool = { _ in true },
         override: @escaping @Sendable ([String]) throws -> Data? = { _ in nil }) {
        self.gate = gate
        self.override = override
    }

    /// Requests are held only while the gate is on. Turn it off to let requests through at once.
    func setGateEnabled(_ on: Bool) { open.set(!on) }

    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    /// Lets the oldest held request for `tag` finish, optionally by failing it.
    func release(_ tag: String, fail: Bool = false) async { await state.release(tag, error: fail ? Boom() : nil) }

    /// Suspends until `count` requests for `tag` have reached the runner.
    func waitForRequest(_ tag: String, count: Int = 1) async {
        for _ in 0..<2000 {
            if await state.arrived(tag) >= count { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func requests() async -> [String] { await state.requests() }

    func run(_ args: [String], stdin: Data?, cwd: URL?) async throws -> Data {
        let tag = Self.tag(args)
        await state.arrive(tag)
        if gate(tag), !open.isOpen { try await state.wait(tag) }
        if let data = try override(args) { return data }
        return try Self.response(tag, args)
    }

    private static func value(_ key: String, in args: [String]) -> String? {
        args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    static func tag(_ args: [String]) -> String {
        if args.first == "pr", args.count > 2 { return "pr:\(args[1]):\(args[2])" }
        if let login = value("login", in: args) { return "repos:\(login)" }
        if let owner = value("owner", in: args), let name = value("name", in: args) { return "prs:\(owner)/\(name)" }
        if let q = value("q", in: args) { return "search:\(q.replacingOccurrences(of: "is:pr is:open sort:created-desc ", with: ""))" }
        return args.joined(separator: " ")
    }

    private static let rate = #"{"remaining":4000,"limit":5000,"cost":1,"resetAt":"2026-10-27T00:00:00Z"}"#

    static func fixtureJSON() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("GHCoreTests/Fixtures/repo_prs.json")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func response(_ tag: String, _ args: [String]) throws -> Data {
        if tag.hasPrefix("repos:") {
            let owner = String(tag.dropFirst(6))
            return Data("""
            {"data":{"rateLimit":\(rate),"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},
            "nodes":[{"name":"\(owner)-repo","owner":{"login":"\(owner)"},"primaryLanguage":null,"pushedAt":"2026-10-26T20:34:12Z",
            "stargazerCount":0,"isArchived":false,"isPrivate":false,"viewerPermission":"ADMIN","autoMergeAllowed":true,
            "hasIssuesEnabled":true,"pullRequests":{"totalCount":1}}]}}}}
            """.utf8)
        }
        if tag.hasPrefix("pr:") { return Data() }
        var json = try fixtureJSON()
        if tag.hasPrefix("search:") {
            var data = json["data"] as! [String: Any]
            let repo = data.removeValue(forKey: "repository") as! [String: Any]
            data["search"] = repo["pullRequests"]
            json["data"] = data
        }
        return try JSONSerialization.data(withJSONObject: json)
    }
}

/// Serves the fixture page again for each cursor with distinct PR numbers (page n adds n * 1000); the last of
/// `pages` reports no next page. PR numbers in `gone` are left out, as if merged meanwhile.
func pagedPRs(pages: Int, gone: Box<Set<Int>> = Box([])) -> @Sendable ([String]) throws -> Data? {
    { args in
        guard args.contains(where: { $0.hasPrefix("owner=") }) else { return nil }
        let page = Int(args.first { $0.hasPrefix("after=") }.map { String($0.dropFirst(6)) } ?? "0") ?? 0
        var json = try GatedGh.fixtureJSON()
        var data = json["data"] as! [String: Any]
        var repo = data["repository"] as! [String: Any]
        var prs = repo["pullRequests"] as! [String: Any]
        var nodes = prs["nodes"] as! [[String: Any]]
        for i in nodes.indices { nodes[i]["number"] = (nodes[i]["number"] as! Int) + page * 1000 }
        prs["nodes"] = nodes.filter { !gone.get().contains($0["number"] as! Int) }
        prs["pageInfo"] = ["hasNextPage": page < pages - 1, "endCursor": "\(page + 1)"]
        repo["pullRequests"] = prs; data["repository"] = repo; json["data"] = data
        return try JSONSerialization.data(withJSONObject: json)
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}
