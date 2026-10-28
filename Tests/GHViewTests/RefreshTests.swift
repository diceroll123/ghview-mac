import Foundation
import Testing
@testable import GHView
@testable import GHCore

private let rate = #"{"remaining":4000,"limit":5000,"cost":1,"resetAt":"2026-10-27T00:00:00Z"}"#

private func node(_ name: String, perm: String) -> String {
    #"{"name":"\#(name)","owner":{"login":"a"},"primaryLanguage":null,"pushedAt":"2026-10-26T20:34:12Z","stargazerCount":0,"isArchived":false,"isPrivate":false,"viewerPermission":"\#(perm)","autoMergeAllowed":false,"hasIssuesEnabled":true,"pullRequests":{"totalCount":3}}"#
}

@Test @MainActor func refreshReloadsRepoMetadataWithoutLosingTheSelection() async {
    let perm = Box("ADMIN"), names = Box(["one"])
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            guard args.contains(where: { $0.hasPrefix("login=") }) else { return nil }
            let nodes = names.get().map { node($0, perm: perm.get()) }.joined(separator: ",")
            return Data(
                #"{"data":{"rateLimit":\#(rate),"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(nodes)]}}}}"#
                    .utf8)
        })
    let model = AppModel(defaults: UserDefaults(suiteName: "rt-\(UUID().uuidString)")!)
    model.settings.showRepoTree = true
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("a")])
    let source = Source.org("a")
    model.toggleExpanded(source)  // the sidebar shows a's repositories
    await model.loadRepos(for: [source])
    model.selectedRepo = RepoId(owner: "a", name: "one")
    #expect(model.currentRepo?.canPush == true)

    // Outside the app: permissions are reduced and a repository is created.
    perm.set("READ"); names.set(["one", "two"])
    await model.loadRepos(for: [source])  // within the cache window, so nothing changes
    #expect(model.repos.count == 1)

    await model.refreshRepos()
    #expect(model.repos(in: source).map(\.id.name) == ["one", "two"])
    #expect(model.currentRepo?.canPush == false)
    #expect(model.selectedRepo == RepoId(owner: "a", name: "one"))  // still selected
}

@Test @MainActor func aSourceFetchesItsReposWhenExpandedAndOnlyOnce() async {
    let gh = GatedGh(gate: { _ in false })
    let model = AppModel(defaults: UserDefaults(suiteName: "rt-\(UUID().uuidString)")!)
    model.settings.showRepoTree = true
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("a"), .org("b")])
    #expect(model.repos.isEmpty && !model.isExpanded(.org("a")))

    model.toggleExpanded(.org("a"))
    for _ in 0..<500 where model.repos(in: .org("a")).isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(model.isExpanded(.org("a")) && model.repos(in: .org("a")).map(\.id.name) == ["a-repo"])
    #expect(model.repos(in: .org("b")).isEmpty)  // other sources stay unfetched

    model.toggleExpanded(.org("a"))  // collapse
    model.toggleExpanded(.org("a"))  // expand again: cached, no new request
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await gh.requests().filter { $0 == "repos:a" }.count == 1)
}
