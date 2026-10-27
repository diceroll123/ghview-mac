import Foundation
import Testing
@testable import GHView
@testable import GHCore

private func threePages() -> @Sendable ([String]) throws -> Data? { pagedPRs(pages: 3) }

@MainActor
private func model(_ gh: GatedGh) -> AppModel {
    let m = AppModel()
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    m.selectedSourceIDs = ["a"]
    m.selectedRepo = RepoId(owner: "diceroll123", name: "ghview")
    return m
}

@MainActor
private func loadFirstPage(_ m: AppModel) async {
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    for _ in 0..<500 where m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
}

@Test @MainActor func aFilterIsFlaggedPartialUntilEverythingIsLoaded() async {
    let m = model(GatedGh(gate: { _ in false }, override: threePages()))
    await loadFirstPage(m)
    #expect(m.hasMorePRs && !m.viewIsPartial)        // newest first with no filter is just the list
    m.sort = .oldest
    #expect(m.viewIsPartial)
    m.sort = .newest; m.filter = "is:draft"
    #expect(m.viewIsPartial)

    await m.loadAllPRs()
    #expect(!m.hasMorePRs && !m.viewIsPartial)
    #expect(m.prs.count % 3 == 0 && Set(m.prs.map(\.id)).count == m.prs.count)
}

@Test @MainActor func loadAllStopsWhenTheUserNavigatesAway() async {
    let gh = GatedGh(gate: { $0.hasPrefix("prs:") }, override: threePages())
    let m = model(gh)
    gh.setGateEnabled(false)
    await loadFirstPage(m)
    gh.setGateEnabled(true)
    let firstPage = m.prs.count

    let all = Task { await m.loadAllPRs() }
    await gh.waitForRequest("prs:diceroll123/ghview", count: 2)
    m.selectedRepo = RepoId(owner: "diceroll123", name: "other")
    m.loadPRs()
    await gh.release("prs:diceroll123/ghview")         // the old repo's second page arrives late
    await all.value
    #expect(!m.loadingAllPRs)
    #expect(m.prs.count != firstPage * 3)
    await gh.waitForRequest("prs:diceroll123/other")
    await gh.release("prs:diceroll123/other")
}
