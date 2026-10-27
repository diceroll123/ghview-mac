import Foundation
import Testing
@testable import GHView
@testable import GHCore

@MainActor
private func model(_ gh: GatedGh) -> AppModel {
    let m = AppModel(defaults: UserDefaults(suiteName: "sb-\(UUID().uuidString)")!,
                     countsURL: FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json"))
    m.connect(gh)
    m.viewer = Viewer(login: "me", orgs: [])
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    return m
}

/// Search requests only: loading PRs also looks up repository permissions, which is not what these tests are about.
private func searches(_ gh: GatedGh) async -> [String] { await gh.requests().filter { $0.hasPrefix("search:") } }

@MainActor
private func waitForPRs(_ m: AppModel) async {
    for _ in 0..<500 where m.prs.isEmpty || m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
}

@Test @MainActor func aShortcutFillsTheBoxWithItsQueryAndLabelsThePanel() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    m.destination = .search(.authored)
    #expect(m.searchText == "author:@me" && m.isSearchDestination && m.sourceTitle == "Authored by me")
    m.loadPRs()
    await waitForPRs(m)
    #expect(!m.prs.isEmpty && m.lastLoadedQuery == "author:@me")
    #expect(await searches(gh) == ["search:author:@me"])

    m.destination = .search(.involves)
    #expect(m.searchText == "involves:@me")                       // each shortcut starts from its own query
    m.destination = .sources(["a"])
    #expect(m.searchText.isEmpty && !m.isSearchDestination)       // sources and repos keep the local filter
}

@Test @MainActor func editingTheBoxRunsTheEditedSearchOnGitHub() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    m.destination = .search(.authored)
    m.loadPRs()
    await waitForPRs(m)

    m.searchText = "author:@me label:bug"
    m.loadPRs()
    for _ in 0..<500 where !(await searches(gh)).contains("search:author:@me label:bug") { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(await searches(gh) == ["search:author:@me", "search:author:@me label:bug"])
    #expect(m.lastLoadedQuery == "author:@me label:bug")
    #expect(m.defaultSearchText == "author:@me")                  // reset goes back to the shortcut's own query
}

@Test @MainActor func aQueryGitHubRefusesShowsBesideTheBoxNotAsAnAlert() async {
    let broken = Box(true)
    let gh = GatedGh(gate: { _ in false }, override: { args in
        if broken.get(), args.contains(where: { $0.hasPrefix("q=") && $0.contains("label:(") }) {
            throw GhError(args: args, status: 1, stderr: "Validation Failed: label:(")
        }
        return nil
    })
    let m = model(gh)
    m.destination = .search(.authored)
    m.searchText = "author:@me label:("
    m.loadPRs()
    for _ in 0..<500 where m.searchError == nil { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.searchError?.contains("Validation Failed") == true)
    #expect(m.error == nil && !m.loadFailed)

    m.searchText = "author:@me"                                  // typing on fixes it
    m.loadPRs()
    await waitForPRs(m)
    #expect(m.searchError == nil && !m.prs.isEmpty)
}

@Test @MainActor func theLocalFilterOnlyAppliesOutsideSearchDestinations() async {
    let m = model(GatedGh(gate: { _ in false }))
    m.destination = .sources(["a"])
    m.loadPRs()
    await waitForPRs(m)
    let all = m.prs.count
    m.filter = "author:nobody-has-this-login"
    #expect(m.visiblePRs.isEmpty && m.isFiltering)

    m.destination = .search(.authored)
    m.loadPRs()
    await waitForPRs(m)
    #expect(m.visiblePRs.count == m.prs.count && !m.isFiltering && all > 0)   // the box is the search here, not a filter
    m.destination = .sources(["a"])
    #expect(m.isFiltering)                                        // the filter text was kept for sources
}

@Test @MainActor func anEmptyBoxClearsTheListInsteadOfSearchingForNothing() async {
    let gh = GatedGh(gate: { _ in false })
    let m = model(gh)
    m.destination = .search(.authored)
    m.loadPRs()
    await waitForPRs(m)
    #expect(!m.prs.isEmpty)

    m.searchText = "   "
    m.loadPRs()
    #expect(m.prs.isEmpty && !m.prsLoading && m.lastLoadedQuery == nil)
    #expect(await searches(gh) == ["search:author:@me"])
}

@Test @MainActor func editingASavedViewsQueryUpdatesTheBox() async throws {
    let m = model(GatedGh(gate: { _ in false }))
    let view = try m.saveView(name: "Bugs", query: "label:bug")
    #expect(m.searchText == "label:bug" && m.sourceTitle == "Bugs")
    m.searchText = "label:bug is:draft"                           // a tweak that is not saved
    #expect(m.layout.savedViews[0].query == "label:bug")
    try m.updateView(view.id, name: "Bugs", query: "label:bug is:draft")   // "Save changes to view"
    #expect(m.layout.savedViews[0].query == "label:bug is:draft" && m.searchText == "label:bug is:draft")
}
