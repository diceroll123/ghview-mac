import Foundation
import Testing
@testable import GHView
@testable import GHCore

private func defaults() -> UserDefaults { UserDefaults(suiteName: "settings-\(UUID().uuidString)")! }

@Test @MainActor func settingsStartOffAndPersist() {
    let d = defaults()
    let s = AppSettings(defaults: d)
    #expect(!s.showRepoTree && !s.hideArchivedRepos && s.contextMenuScope == .clickedOnly)   // all off by default

    s.showRepoTree = true
    s.hideArchivedRepos = true
    s.contextMenuScope = .allSelected
    let again = AppSettings(defaults: d)
    #expect(again.showRepoTree && again.hideArchivedRepos && again.contextMenuScope == .allSelected)
    #expect(AppSettings(defaults: defaults()).contextMenuScope == .clickedOnly)               // another store is unaffected
}

@Test @MainActor func aCorruptContextMenuSettingFallsBackToTheSafeDefault() {
    let d = defaults()
    d.set("everything", forKey: "settings.contextMenuScope")
    #expect(AppSettings(defaults: d).contextMenuScope == .clickedOnly)
}

@Test @MainActor func repoSubtitleEntriesDefaultToLanguageAndLockOnlyAndPersistReordering() {
    let d = defaults()
    let s = AppSettings(defaults: d)
    #expect(s.repoSubtitleEntries.enabled() == [.language, .lockIcon])

    let first = s.repoSubtitleEntries.removeFirst()
    s.repoSubtitleEntries.append(first)                                   // reorder, as dragging a row would
    s.repoSubtitleEntries[s.repoSubtitleEntries.firstIndex { $0.item == .releaseTag }!].enabled = true
    let order: [RepoSubtitleItem] = s.repoSubtitleEntries.map(\.item)

    let again = AppSettings(defaults: d)
    #expect(again.repoSubtitleEntries.map(\.item) == order)
    #expect(again.repoSubtitleEntries.enabled().contains(.releaseTag))
}

@Test @MainActor func sourceBadgeEntriesDefaultToReviewAndOpenCountsAndPersist() {
    let d = defaults()
    let s = AppSettings(defaults: d)
    #expect(s.sourceBadgeEntries.enabled() == [.reviewRequested, .openPRs])

    s.sourceBadgeEntries[s.sourceBadgeEntries.firstIndex { $0.item == .repoCount }!].enabled = true
    let again = AppSettings(defaults: d)
    #expect(again.sourceBadgeEntries.enabled() == [.reviewRequested, .openPRs, .repoCount])
}

@Test @MainActor func sourceBadgeColorsDefaultMatchTheOldLookAndPersist() {
    let d = defaults()
    let s = AppSettings(defaults: d)
    #expect(s.sourceBadgeEntries.first { $0.item == .reviewRequested }?.color == .accent)
    #expect(s.sourceBadgeEntries.first { $0.item == .openPRs }?.color == .plain)
    #expect(s.sourceBadgeEntries.first { $0.item == .repoCount }?.color == .plain)

    s.sourceBadgeEntries[s.sourceBadgeEntries.firstIndex { $0.item == .openPRs }!].color = .green
    let again = AppSettings(defaults: d)
    #expect(again.sourceBadgeEntries.first { $0.item == .openPRs }?.color == .green)
    #expect(again.sourceBadgeEntries.first { $0.item == .reviewRequested }?.color == .accent)
}


@MainActor
private func modelWithPRs() async -> AppModel {
    let gh = GatedGh(gate: { _ in false })
    let m = AppModel(defaults: defaults())
    m.connect(gh)
    m.destination = .repo(RepoId(owner: "diceroll123", name: "ghview"))
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty || m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    return m
}

@Test @MainActor func rightClickActsOnlyOnTheClickedPRByDefault() async {
    let m = await modelWithPRs()
    let (a, b, c) = (m.prs[0], m.prs[1], m.prs[2])
    m.selection.toggle(a.id); m.selection.toggle(b.id)

    #expect(m.contextTargets(for: a).map(\.id) == [a.id])          // one of two selected: still just this one
    #expect(m.contextTargets(for: c).map(\.id) == [c.id])
    #expect(m.actionTargets.map(\.id) == [a.id, b.id])             // the action bar still acts on the selection
}

@Test @MainActor func theSettingMakesARightClickOnASelectedPRActOnAllSelected() async {
    let m = await modelWithPRs()
    let (a, b, c) = (m.prs[0], m.prs[1], m.prs[2])
    m.selection.toggle(a.id); m.selection.toggle(b.id)
    m.settings.contextMenuScope = .allSelected

    #expect(m.contextTargets(for: a).map(\.id) == [a.id, b.id])
    #expect(m.contextTargets(for: c).map(\.id) == [c.id])          // an unselected PR is only itself either way
}

@Test @MainActor func theRepoTreeIsOffUnlessAskedFor() async {
    let gh = GatedGh(gate: { _ in false })
    let m = AppModel(defaults: defaults())
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    m.toggleExpanded(.org("a"))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!m.isExpanded(.org("a")) && m.repos.isEmpty)           // nothing expands, nothing is fetched
    #expect(await gh.requests().isEmpty)

    m.settings.showRepoTree = true
    m.toggleExpanded(.org("a"))
    for _ in 0..<500 where m.repos.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.isExpanded(.org("a")) && !m.repos.isEmpty)
}

private func archivedOverride() -> @Sendable ([String]) -> Data? {
    { args in
        guard args.contains(where: { $0.hasPrefix("login=") }) else { return nil }
        func node(_ n: String, archived: Bool, priv: Bool) -> String {
            #"{"name":"\#(n)","owner":{"login":"a"},"primaryLanguage":null,"pushedAt":"2026-10-26T20:34:12Z","stargazerCount":0,"isArchived":\#(archived),"isPrivate":\#(priv),"viewerPermission":"ADMIN","autoMergeAllowed":true,"hasIssuesEnabled":true,"pullRequests":{"totalCount":1}}"#
        }
        return Data(#"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\#(node("live", archived: false, priv: false)),\#(node("old", archived: true, priv: false)),\#(node("secret", archived: false, priv: true))]}}}}"#.utf8)
    }
}

@Test @MainActor func archivedReposAreListedAndMarkedUnlessTheSettingHidesThem() async {
    let m = AppModel(defaults: defaults())
    m.connect(GatedGh(gate: { _ in false }, override: archivedOverride()))
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    await m.loadRepos(for: [.org("a")])

    #expect(m.repos(in: .org("a")).map(\.id.name) == ["live", "old", "secret"])      // archived is shown by default
    #expect(m.repos(in: .org("a")).first { $0.id.name == "old" }?.isArchived == true)
    #expect(m.repos(in: .org("a")).first { $0.id.name == "secret" }?.isPrivate == true)

    m.settings.hideArchivedRepos = true
    #expect(m.repos(in: .org("a")).map(\.id.name) == ["live", "secret"])
    #expect(m.repoInfo(for: RepoId(owner: "a", name: "old"))?.isArchived == true)    // permissions still know it is archived
}

@Test @MainActor func actionsOnAnArchivedReposPRsExplainWhy() async {
    let m = AppModel(defaults: defaults())
    m.connect(GatedGh(gate: { _ in false }, override: archivedOverride()))
    m.viewer = Viewer(login: "me", orgs: [])
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    await m.loadRepos(for: [.org("a")])
    var pr = PR(id: PrId(repo: RepoId(owner: "a", name: "old"), number: 1), title: "t", author: "me", isDraft: false, isOpen: true,
                createdAt: Date(), updatedAt: Date(), url: "u", headRef: "h", baseRef: "main", headSha: "s", additions: 0, deletions: 0,
                comments: 0, autoMerge: false, reviewStatus: .unknown, viewerApproved: false, mergeable: .clean,
                requestedReviewers: [], labels: [], checks: [], checkSummary: .unknown)
    pr.isOpen = true
    #expect(m.unavailableReason(.merge, for: [pr])?.contains("archived") == true)
}

@Test @MainActor func aRepoCanBeAddedToSourcesFromAnywhereItIsShown() async {
    let gh = GatedGh(gate: { _ in false })
    let m = AppModel(defaults: defaults())
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.user("me")])
    let repo = RepoId(owner: "acme", name: "api")
    #expect(!m.isSource(repo))

    m.destination = .sources(["me"])
    m.addRepoSource(repo)
    #expect(m.isSource(repo))
    #expect(m.destination == .sources(["me"]))                      // adding from a menu does not navigate away
    #expect(m.catalog.groups.last?.name == "Repositories")

    m.addRepoSource(repo)                                           // adding it again is a harmless no-op
    #expect(m.catalog.allSources.filter { $0 == .repo("acme/api") }.count == 1)
}

@Test @MainActor func aRepoSourceLoadsItsPRsThroughARepoSearchAndNeverListsRepos() async {
    let gh = GatedGh(gate: { _ in false })
    let m = AppModel(defaults: defaults())
    m.settings.showRepoTree = true
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.repo("acme/api"), .org("acme")])
    m.toggleExpanded(.repo("acme/api"))                              // not expandable: it is one repository
    await m.loadRepos(for: m.catalog.allSources)
    let requests = await gh.requests()
    #expect(!m.isExpanded(.repo("acme/api")) && requests == ["repos:acme"])   // only the org was enumerated

    m.destination = .sources(["acme/api"])
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(await gh.requests().contains("search:repo:acme/api"))
    #expect(m.sourceTitle == "acme/api")
}
