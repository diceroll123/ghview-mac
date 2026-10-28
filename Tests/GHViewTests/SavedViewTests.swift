import Foundation
import Testing
@testable import GHView
@testable import GHCore

@MainActor
private func model(_ gh: GatedGh, defaults: UserDefaults? = nil) -> AppModel {
    let m = AppModel(
        defaults: defaults ?? UserDefaults(suiteName: "views-\(UUID().uuidString)")!,
        countsURL: FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json"))
    m.connect(gh)
    m.viewer = Viewer(login: "me", orgs: [])
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    return m
}

@Test @MainActor func aSavedViewIsCreatedOpenedEditedAndDeleted() async throws {
    let m = model(GatedGh(gate: { _ in false }))
    let view = try m.saveView(name: " Bugs ", query: " label:bug org:acme ")
    #expect(view.name == "Bugs" && view.query == "label:bug org:acme")
    #expect(m.destination == .savedView(view.id) && m.sourceTitle == "Bugs")

    #expect(throws: SavedViewError.duplicateName("bugs")) { try m.saveView(name: "bugs", query: "x") }
    #expect(m.layout.savedViews.count == 1)

    try m.updateView(view.id, name: "Open bugs", query: "label:bug")
    #expect(m.layout.savedViews[0].name == "Open bugs" && m.layout.savedViews[0].query == "label:bug")
    #expect(m.sourceTitle == "Open bugs")

    m.deleteView(view.id)
    #expect(m.layout.savedViews.isEmpty)
    #expect(m.destination == .sources(["a"]))  // the open view went away: back to a source
}

@Test @MainActor func openingASavedViewRunsItsQueryAndEditingReloadsIt() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    let view = try! m.saveView(name: "Stale", query: "updated:<2025-01-01 org:acme")
    m.loadPRs()
    await gh.waitForRequest("search:updated:<2025-01-01 org:acme")
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(!m.prs.isEmpty)

    try! m.updateView(view.id, name: "Stale", query: "label:old")
    await gh.waitForRequest("search:label:old")  // changing the query reloads the open view
    #expect(await gh.requests().contains("search:label:old"))
}

@Test @MainActor func aViewWithNoRunnableQueryDoesNotLoadAnything() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    m.layout.savedViews = [SavedView(name: "Blank", query: "   ")]  // can only come from a hand-edited file
    m.destination = .savedView(m.layout.savedViews[0].id)
    m.loadPRs()
    try? await Task.sleep(for: .milliseconds(30))
    let sent = await gh.requests()
    #expect(m.prs.isEmpty && !m.prsLoading && sent.isEmpty)
}

@Test @MainActor func viewCountsComeWithTheShortcutCountsAndBadQueriesAreFlagged() async {
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            guard args.contains(where: { $0.hasPrefix("q0=") }) else { return nil }
            // q0..q3 are the shortcuts, q4 the good view, q5 the broken one
            return Data(
                #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":{"issueCount":1},"o1":{"issueCount":2},"o2":{"issueCount":3},"o3":{"issueCount":4},"o4":{"issueCount":9},"o5":null},"errors":[{"message":"Validation Failed","path":["o5"]}]}"#
                    .utf8)
        })
    let m = model(gh)
    m.layout.savedViews = [SavedView(name: "Good", query: "label:bug"), SavedView(name: "Broken", query: "label:(")]
    await m.loadSearchCounts()
    #expect(m.count(for: m.layout.savedViews[0]) == 9)
    #expect(m.count(for: m.layout.savedViews[1]) == nil)
    #expect(m.searchCountErrors["label:("] == "Validation Failed")

    m.layout.hiddenEntries = ["view:\(m.layout.savedViews[1].id.uuidString)"]
    #expect(m.layout.visibleViews.map(\.name) == ["Good"])
}

@Test @MainActor func theEditorChecksAQueryAgainstGitHubAsYouType() async {
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            guard args.contains(where: { $0.hasPrefix("q0=") }) else { return nil }
            if args.contains(where: { $0.contains("bad(") }) {
                return Data(
                    #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":null},"errors":[{"message":"Validation Failed","path":["o0"]}]}"#
                        .utf8)
            }
            return Data(#"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":{"issueCount":6}}}"#.utf8)
        })
    let m = model(gh)
    #expect(await m.previewCount(for: "label:bug").count == 6)
    #expect(await m.previewCount(for: "bad(").error == "Validation Failed")
    let blank = await m.previewCount(for: "  ")
    #expect(blank.count == nil && blank.error == nil)
    #expect(!(await gh.requests()).isEmpty)
}

@Test @MainActor func hidingAViewOrTheBlockKeepsItsDataAndFallsBack() async throws {
    let m = model(GatedGh(gate: { _ in false }))
    let view = try m.saveView(name: "Bugs", query: "label:bug")
    m.hideEntry(SidebarDestination.savedView(view.id).tag)
    #expect(m.destination == .sources(["a"]) && m.layout.savedViews.count == 1)  // hidden, not deleted

    m.showHiddenEntries()
    m.destination = .savedView(view.id)
    m.setSavedViewsHidden(true)
    #expect(m.destination == .sources(["a"]) && m.layout.savedViews.count == 1)
    m.setSavedViewsHidden(false)
    #expect(m.layout.visibleViews.count == 1)
}

@Test @MainActor func savedViewsSurviveARelaunchForTheSameAccountOnly() throws {
    let defaults = UserDefaults(suiteName: "views-\(UUID().uuidString)")!
    let alice = AccountScope(login: "alice")
    var layout = SidebarLayout()
    layout.savedViews = [SavedView(name: "Mine", query: "author:@me label:wip")]
    layout.save(to: defaults, scope: alice)

    #expect(SidebarLayout.load(from: defaults, scope: alice).savedViews.map(\.name) == ["Mine"])
    #expect(SidebarLayout.load(from: defaults, scope: AccountScope(login: "bob")).savedViews.isEmpty)
}

@Test @MainActor func hidingTheViewsGroupAlsoStopsCountingTheBuiltInSearches() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    m.layout.savedViewsHidden = true
    await m.loadSearchCounts()
    #expect(await gh.requests().isEmpty)  // nothing visible to count, so no query
}
