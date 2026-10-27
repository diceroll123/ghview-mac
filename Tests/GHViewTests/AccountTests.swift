import Foundation
import Testing
@testable import GHView
@testable import GHCore

private func isolatedDefaults() -> UserDefaults {
    let name = "ghview-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A gh signed in as `login`, whose identity can be changed under the app's feet.
private func gh(as login: Box<String>) -> GatedGh {
    GatedGh(gate: { $0.hasPrefix("pr:") }, override: { args in
        if args.contains(where: { $0.contains("viewer { login") }) {
            var json = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("GHCoreTests/Fixtures/viewer.json"))) as? [String: Any])
            var data = json["data"] as! [String: Any]
            var viewer = data["viewer"] as! [String: Any]
            viewer["login"] = login.get()
            viewer["organizations"] = ["pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": [["login": "\(login.get())-org"]]]
            data["viewer"] = viewer; json["data"] = data
            return try JSONSerialization.data(withJSONObject: json)
        }
        if args.starts(with: ["api", "user"]) { return Data((login.get() + "\n").utf8) }
        return nil
    })
}

@MainActor
private func model(_ defaults: UserDefaults, _ dir: URL) -> AppModel {
    AppModel(defaults: defaults, countsURL: dir.appendingPathComponent("source-counts.json"))
}

@Test @MainActor func twoAccountsNeverSeeEachOthersSourcesOrCounts() async {
    let defaults = isolatedDefaults(), dir = tempDir()
    let login = Box("alice")

    let a = model(defaults, dir)
    await a.start(runner: { gh(as: login) })
    #expect(a.account == AccountScope(login: "alice"))
    a.catalog.setHidden(a.allSources.filter { $0.name == "alice-org" }, true)   // alice customises her sources
    a.counts = ["alice-org": SourceCounts(open: 7, reviewRequested: 2, error: nil)]
    SourceCountsCache.save(a.counts, to: a.countsURL)
    a.catalog.save(to: defaults, key: AccountScope(login: "alice").catalogKey)

    login.set("bob")                                   // gh is switched to another account and the app relaunched
    let b = model(defaults, dir)
    await b.start(runner: { gh(as: login) })
    #expect(b.account == AccountScope(login: "bob"))
    #expect(b.allSources.map(\.name).contains("bob-org") && !b.allSources.map(\.name).contains("alice-org"))
    #expect(b.counts["alice-org"] == nil)

    login.set("alice")                                 // and back: alice's own state is intact
    let again = model(defaults, dir)
    await again.start(runner: { gh(as: login) })
    #expect(again.counts["alice-org"]?.open == 7)
    #expect(again.catalog.isHidden(again.allSources.first { $0.name == "alice-org" }!))
}

@Test @MainActor func theOldSharedStateIsAdoptedByTheFirstAccountOnlyOnce() async {
    let defaults = isolatedDefaults(), dir = tempDir()
    let old = SourceCatalog.seeded(from: [.org("legacy-org")])
    old.save(to: defaults)                             // the pre-accounts key
    SourceCountsCache.save(["legacy-org": SourceCounts(open: 3, reviewRequested: 0, error: nil)], to: dir.appendingPathComponent("source-counts.json"))
    let login = Box("alice")

    let a = model(defaults, dir)
    await a.start(runner: { gh(as: login) })
    #expect(a.allSources.map(\.name).contains("legacy-org"))
    #expect(a.counts["legacy-org"]?.open == 3)
    #expect(SourceCatalog.load(from: defaults) == nil) // the shared copy is gone

    login.set("bob")
    let b = model(defaults, dir)
    await b.start(runner: { gh(as: login) })
    #expect(!b.allSources.map(\.name).contains("legacy-org"))
    #expect(b.counts["legacy-org"] == nil)
}

@Test @MainActor func aSwitchedGhAccountStopsActionsInsteadOfActingAsSomeoneElse() async {
    let login = Box("alice")
    let runner = gh(as: login)
    let m = model(isolatedDefaults(), tempDir())
    await m.start(runner: { runner })
    m.selectedRepo = RepoId(owner: "diceroll123", name: "ghview")
    runner.setGateEnabled(false)
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    for _ in 0..<500 where m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    runner.setGateEnabled(true)
    m.repos = Set(m.prs.map(\.repo)).map {
        RepoInfo(id: $0, language: nil, pushedAt: nil, stars: 0, openPRs: 0, isArchived: false, isPrivate: false,
                 canPush: true, allowAutoMerge: true, hasIssues: true)
    }
    let pr = m.prs[0]

    login.set("mallory")                               // `gh auth switch` in a terminal
    m.perform(.close, on: [pr], confirmed: true)
    for _ in 0..<200 where !m.busy.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(m.connection == .problem(.accountChanged(was: "alice", now: "mallory")))
    #expect(await runner.requests().filter { $0.hasPrefix("pr:") }.isEmpty)       // nothing was sent
    #expect(m.status?.contains("account changed") == true)

    await m.start(runner: { runner })                  // Retry switches over to the new account explicitly
    #expect(m.account == AccountScope(login: "mallory"))
    #expect(m.connection == .connected)
    #expect(m.prs.isEmpty)                             // alice's PRs are gone with her session
}

@Test @MainActor func accountScopesAreKeyedByHostAndCaseInsensitiveLogin() {
    #expect(AccountScope(login: "Alice") == AccountScope(login: "Alice"))
    #expect(AccountScope(login: "Alice").id == AccountScope(login: "alice").id)
    #expect(AccountScope(login: "alice").catalogKey != AccountScope(login: "bob").catalogKey)
    #expect(AccountScope(login: "alice").countsFileName != AccountScope(host: "ghe.example.com", login: "alice").countsFileName)
    #expect(AppModel.scope(fromID: "github.com/alice")?.id == "github.com/alice")
    #expect(ConnectionProblem.unsupportedHost("ghe.example.com").advice.contains("github.com only"))
}
