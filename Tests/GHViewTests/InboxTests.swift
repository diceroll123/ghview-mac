import Foundation
import Testing
@testable import GHView
@testable import GHCore

private struct Item {
    var author = "me"
    var draft = false
    var decision: String? = nil
    var merge = "MERGEABLE"
    var users: [String] = []
    var teams: [String] = []
}

/// A search response built from the recorded PR fixture, one node per item with the fields that decide its section.
private func searchJSON(_ items: [Item], base: Int) throws -> Data {
    var json = try GatedGh.fixtureJSON()
    var data = json["data"] as! [String: Any]
    let repo = data.removeValue(forKey: "repository") as! [String: Any]
    var conn = repo["pullRequests"] as! [String: Any]
    let template = (conn["nodes"] as! [[String: Any]])[0]
    conn["nodes"] = items.enumerated().map { i, item -> [String: Any] in
        var n = template
        n["number"] = base + i
        n["author"] = ["login": item.author]
        n["isDraft"] = item.draft
        n["reviewDecision"] = item.decision as Any? ?? NSNull()
        n["mergeable"] = item.merge
        n["commits"] = ["nodes": [] as [Any]]  // no checks at all
        var requests: [[String: Any]] = item.users.map { ["requestedReviewer": ["login": $0]] }
        requests += item.teams.map { ["requestedReviewer": ["slug": $0, "organization": ["login": "acme"]]] }
        n["reviewRequests"] = ["totalCount": requests.count]
        n["reviewRequestNodes"] = ["nodes": requests]
        return n
    }
    conn["pageInfo"] = ["hasNextPage": false, "endCursor": NSNull()]
    conn["issueCount"] = items.count
    data["search"] = conn
    json["data"] = data
    return try JSONSerialization.data(withJSONObject: json)
}

private let mine: [Item] = [
    Item(draft: true),  // your drafts
    Item(decision: "CHANGES_REQUESTED"),  // needs action
    Item(decision: "APPROVED", merge: "MERGEABLE"),  // ready to merge
    Item(decision: "REVIEW_REQUIRED"),  // waiting
    Item(decision: "APPROVED", merge: "CONFLICTING"),  // needs action (conflict)
]
private let asked: [Item] = [
    Item(author: "alice", users: ["me"]),  // needs your review
    Item(author: "bob", users: ["zed"], teams: ["core"]),  // needs your teams' review
]

@MainActor
private func model(_ gh: GatedGh, defaults: UserDefaults? = nil) -> AppModel {
    let m = AppModel(
        defaults: defaults ?? UserDefaults(suiteName: "inbox-\(UUID().uuidString)")!,
        countsURL: FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json"))
    m.connect(gh)
    m.viewer = Viewer(login: "me", orgs: [])
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    return m
}

private func inboxGh(failing scope: String? = nil, gate: @escaping @Sendable (String) -> Bool = { _ in false }) -> GatedGh {
    GatedGh(
        gate: gate,
        override: { args in
            guard let q = args.first(where: { $0.hasPrefix("q=") }) else { return nil }
            if let scope, q.contains(scope) { throw GhError(args: args, status: 1, stderr: "Validation Failed for \(scope)") }
            if q.contains("author:@me") { return try searchJSON(mine, base: 100) }
            if q.contains("review-requested:@me") { return try searchJSON(asked, base: 200) }
            return try searchJSON([Item(author: "x")], base: 300)  // quick searches and saved views
        })
}

@Test @MainActor func theInboxLoadsBothSearchesAndCountsEachSection() async {
    let gh = inboxGh()
    let m = model(gh)
    await m.loadInbox()
    #expect(m.inboxPRs.count == 7)
    #expect(m.inboxCounts == [.yourDrafts: 1, .needsAction: 2, .readyToMerge: 1, .waiting: 1, .needsYourReview: 1, .needsTeamsReview: 1])
    #expect(Set(await gh.requests()) == ["search:author:@me", "search:review-requested:@me"])
}

@Test @MainActor func selectingASectionShowsOnlyItsPRsInTheFlatList() async {
    let m = model(inboxGh())
    m.destination = .inbox(.needsAction)
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty || m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.prs.map(\.number).sorted() == [101, 104])
    #expect(!m.hasMorePRs && m.hasLoadedPRs && m.sourceTitle == "Needs action")
    #expect(m.label(for: m.prs[0]).contains("/"))  // owner/repo#n: the list mixes owners

    m.destination = .inbox(.needsYourReview)
    m.loadPRs()
    for _ in 0..<500 where m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.prs.map(\.number) == [200])
}

@Test @MainActor func oneFailingSearchKeepsTheOtherAndIsReported() async {
    let m = model(inboxGh(failing: "review-requested"))
    await m.loadInbox()
    #expect(m.inboxPRs.count == 5)  // the authored PRs
    #expect(m.inboxFailures.map(\.scope) == ["review-requested:@me"])
    #expect(m.inboxCounts[.needsYourReview] == nil && m.inboxCounts[.yourDrafts] == 1)

    m.destination = .inbox(.yourDrafts)
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.prFailures.map(\.scope) == ["review-requested:@me"])  // the list says what is missing
}

@Test @MainActor func aQuickSearchLoadsThroughItsOwnQuery() async {
    let gh = inboxGh()
    let m = model(gh)
    m.destination = .search(.assigned)
    m.loadPRs()
    await gh.waitForRequest("search:assignee:@me")
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.prs.count == 1 && m.sourceTitle == "Assigned to me")
    #expect(!(await gh.requests()).contains("search:author:@me"))  // the inbox is not touched
}

@Test @MainActor func searchCountsFillTheShortcutBadges() async {
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            guard args.contains(where: { $0.hasPrefix("q0=") }) else { return nil }
            return Data(
                #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":{"issueCount":12},"o1":{"issueCount":1},"o2":{"issueCount":20},"o3":{"issueCount":4}}}"#
                    .utf8)
        })
    let m = model(gh)
    await m.loadSearchCounts()
    #expect(m.count(for: .authored) == 12 && m.count(for: .assigned) == 1)
    #expect(m.count(for: .involves) == 20 && m.count(for: .reviewRequests) == 4)

    m.layout.hiddenEntries = ["search:involves"]
    m.searchCounts = [:]
    await m.loadSearchCounts()
    #expect(m.count(for: .involves) == nil)  // hidden entries are not even counted
}

@Test @MainActor func aHiddenInboxSendsNoQueries() async {
    let gh = inboxGh()
    let m = model(gh)
    m.layout.inboxHidden = true
    #expect(!m.layout.needsInboxData)
    // start() and the timer only load the inbox when something needs it; hiding must also keep it from loading later.
    m.setQuickSearchesHidden(true)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!(await gh.requests()).contains("search:author:@me"))

    m.setInboxHidden(false)  // bringing it back loads it
    for _ in 0..<500 where !m.inboxLoaded { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.inboxLoaded && m.inboxPRs.count == 7)
}

@Test @MainActor func hidingTheSelectedEntryFallsBackToASource() async {
    let m = model(inboxGh())
    m.destination = .inbox(.waiting)
    m.hideEntry(SidebarDestination.inbox(.waiting).tag)
    #expect(m.destination == .sources(["a"]))
    #expect(m.layout.hiddenEntryCount == 1)

    m.destination = .search(.involves)
    m.setQuickSearchesHidden(true)
    #expect(m.destination == .sources(["a"]))
    m.showHiddenEntries()
    #expect(m.layout.hiddenEntryCount == 0 && m.layout.visibleSections.count == 6)
}

@Test @MainActor func aBackgroundReloadUpdatesTheSelectedSectionInPlace() async {
    let drafts = Box<[Item]>(mine)
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            guard let q = args.first(where: { $0.hasPrefix("q=") }) else { return nil }
            return q.contains("author:@me") ? try searchJSON(drafts.get(), base: 100) : try searchJSON([], base: 200)
        })
    let m = model(gh)
    m.destination = .inbox(.yourDrafts)
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.prs.count == 1)

    drafts.set(mine + [Item(draft: true), Item(draft: true)])  // two more drafts appear on GitHub
    await m.loadInbox()  // the 5 minute timer
    #expect(m.prs.count == 3)
}

@Test @MainActor func everythingHiddenAtTheTopCanBeBroughtBackInOneStep() async throws {
    let m = model(inboxGh())
    let view = try m.saveView(name: "Mine", query: "label:wip")
    m.setInboxHidden(true)
    m.setQuickSearchesHidden(true)
    m.setSavedViewsHidden(true)
    m.hideEntry("inbox:needsAction")
    #expect(m.hiddenSidebarCount == 4)

    m.showAllSidebarItems()
    #expect(m.hiddenSidebarCount == 0)
    #expect(m.layout.visibleSections.count == 6 && m.layout.visibleSearches.count == 4)
    #expect(m.layout.savedViews.map(\.id) == [view.id] && m.layout.visibleViews.count == 1)  // views are never lost
}

@Test @MainActor func resetToDefaultsAlsoBringsTheTopOfTheSidebarBack() async {
    let m = model(inboxGh())
    m.setInboxHidden(true)
    m.setQuickSearchesHidden(true)
    m.resetSources()
    #expect(m.hiddenSidebarCount == 0)
}

@Test @MainActor func anInboxSectionShowsItsQueryReadOnlyAndIgnoresTheLocalFilter() async {
    let m = model(inboxGh())
    m.destination = .inbox(.needsAction)
    #expect(m.inboxQueryText == InboxSection.needsAction.queryText && m.inboxQueryNote != nil)
    #expect(m.isInboxDestination && !m.isSearchDestination)
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }

    m.filter = "author:nobody-has-this-login"  // a leftover local filter must not hide the section
    #expect(m.visiblePRs.count == m.prs.count && !m.isFiltering)

    m.destination = .sources(["a"])
    #expect(m.inboxQueryText == nil && m.isFiltering)  // sources keep the editable local filter
}
