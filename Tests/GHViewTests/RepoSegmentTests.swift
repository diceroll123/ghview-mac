import Foundation
import Testing
@testable import GHView
@testable import GHCore

@MainActor
private func model(_ gh: GatedGh, sources: [Source] = [.org("a"), .org("b")]) -> AppModel {
    let m = AppModel(defaults: UserDefaults(suiteName: "seg-\(UUID().uuidString)")!)
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: sources)
    return m
}

private func searches(_ gh: GatedGh) async -> [String] { await gh.requests().filter { $0.hasPrefix("search:") || $0.hasPrefix("prs:") } }

@Test @MainActor func theSegmentAppliesToSourcesAndToARepoOpenedFromTheirList() {
    let m = model(GatedGh(gate: { _ in false }))
    #expect(!m.showsSourceSegment)  // nothing selected
    m.destination = .inbox(.needsAction)
    #expect(!m.showsSourceSegment)
    m.destination = .search(.authored)
    #expect(!m.showsSourceSegment)
    m.destination = .sources(["a"])
    #expect(m.showsSourceSegment && !m.showsRepoPane)  // PRs is the default side
    m.setBrowsingRepos(true)
    #expect(m.showsRepoPane)
    m.openRepo(RepoId(owner: "a", name: "a-repo"))
    #expect(m.showsSourceSegment && m.showsRepoPane)  // the list stays, with the segment above it
    m.destination = .inbox(.waiting)
    #expect(!m.showsSourceSegment && !m.showsRepoPane)
}

@Test @MainActor func reposShowsTheSourcesRepositoriesAndPickingOneOpensItsPRs() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    m.destination = .sources(["a"])
    m.setBrowsingRepos(true)
    #expect(m.isBrowsingRepos)
    for _ in 0..<500 where m.browsedRepos.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.browsedRepos.map(\.id.name) == ["a-repo"])
    #expect(await searches(gh).isEmpty)  // no PRs were fetched for a list of repos

    m.openRepo(RepoId(owner: "a", name: "a-repo"))
    #expect(m.destination == .repo(RepoId(owner: "a", name: "a-repo")))
    #expect(m.showsRepoPane && m.browsedRepos.map(\.id.name) == ["a-repo"])  // the list did not go away
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(!m.prs.isEmpty)
}

@Test @MainActor func theListStaysWhileSwitchingBetweenReposAndPRsGoesBackToTheSource() async {
    let m = model(GatedGh(gate: { _ in false }))
    m.destination = .sources(["a", "b"])
    m.setBrowsingRepos(true)
    m.openRepo(RepoId(owner: "a", name: "a-repo"))
    m.openRepo(RepoId(owner: "b", name: "b-repo"))  // switching repos does not close the list
    #expect(m.showsRepoPane && m.selectedRepo == RepoId(owner: "b", name: "b-repo"))

    m.setBrowsingRepos(false)  // PRs: all of the sources' PRs again
    #expect(m.destination == .sources(["a", "b"]) && !m.showsRepoPane && !m.browsingRepos)
    m.setBrowsingRepos(true)
    #expect(m.destination == .sources(["a", "b"]) && m.showsRepoPane)
}

@Test @MainActor func aRepoPickedAnywhereElseDoesNotOpenTheList() {
    let m = model(GatedGh(gate: { _ in false }))
    m.destination = .sources(["a"])
    m.setBrowsingRepos(true)
    m.destination = .repo(RepoId(owner: "a", name: "a-repo"))  // e.g. a repo row in the sidebar tree
    #expect(!m.browsingRepos && !m.showsRepoPane && !m.showsSourceSegment)
}

@Test @MainActor func severalSourcesListTheirReposTogetherNewestFirst() async {
    let m = model(GatedGh(gate: { _ in false }))
    m.destination = .sources(["a", "b"])
    m.setBrowsingRepos(true)
    for _ in 0..<500 where m.browsedRepos.count < 2 { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(Set(m.browsedRepos.map(\.id.fullName)) == ["a/a-repo", "b/b-repo"])
}

@Test @MainActor func aRepositorySourceListsItselfAndArchivedOnesFollowTheSetting() async {
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            guard args.contains(where: { $0.hasPrefix("login=") }) else { return nil }
            func node(_ n: String, archived: Bool) -> String {
                #"{"name":"\#(n)","owner":{"login":"a"},"primaryLanguage":null,"pushedAt":"2026-10-26T20:34:12Z","stargazerCount":0,"isArchived":\#(archived),"isPrivate":false,"viewerPermission":"ADMIN","autoMergeAllowed":true,"hasIssuesEnabled":true,"pullRequests":{"totalCount":1}}"#
            }
            return Data(
                #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(node("live", archived: false)),\#(node("old", archived: true))]}}}}"#
                    .utf8)
        })
    let m = model(gh)
    m.destination = .sources(["a"])
    m.setBrowsingRepos(true)
    for _ in 0..<500 where m.browsedRepos.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.browsedRepos.map(\.id.name) == ["live", "old"])
    m.settings.hideArchivedRepos = true
    #expect(m.browsedRepos.map(\.id.name) == ["live"])
}

@Test @MainActor func togglingBackToPRsLoadsThemAndLeavingSourcesEndsBrowsing() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    m.destination = .sources(["a"])
    m.setBrowsingRepos(true)
    m.setBrowsingRepos(false)
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(!m.prs.isEmpty && !m.isBrowsingRepos)

    m.setBrowsingRepos(true)
    m.destination = .inbox(.waiting)
    #expect(!m.browsingRepos)  // not sticky across destination kinds
}

@Test @MainActor func switchingSourcesWhileBrowsingKeepsBrowsing() async {
    let m = model(GatedGh(gate: { _ in false }))
    m.destination = .sources(["a"])
    m.setBrowsingRepos(true)
    m.destination = .sources(["b"])
    #expect(m.isBrowsingRepos && m.paneSourceIDs == ["b"])
    m.loadPRs()
    for _ in 0..<500 where m.browsedRepos.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.browsedRepos.map(\.id.name) == ["b-repo"])
}

@Test @MainActor func aRepositoryAddedAsASourceHasNoSegment() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh, sources: [.org("a"), .repo("acme/api")])
    m.destination = .sources(["acme/api"])
    #expect(!m.showsSourceSegment && !m.isBrowsingRepos)  // a single repo: nothing to list
    m.setBrowsingRepos(true)  // ignored
    #expect(!m.isBrowsingRepos)
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(!m.prs.isEmpty)  // it shows PRs, never an empty repo list

    m.destination = .sources(["a", "acme/api"])  // mixed with an organization: it has repos to list
    #expect(m.showsSourceSegment)
    m.setBrowsingRepos(true)
    m.destination = .sources(["acme/api"])
    #expect(!m.isBrowsingRepos)  // switching to only a repo source leaves list mode
}
