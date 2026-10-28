import Foundation
import Testing
@testable import GHView
@testable import GHCore

@MainActor
private func loadedEverything(_ gh: GatedGh) async -> AppModel {
    let m = AppModel()
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.org("a")])
    m.selectedSourceIDs = ["a"]
    m.selectedRepo = RepoId(owner: "diceroll123", name: "ghview")
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    for _ in 0..<500 where m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    await m.loadAllPRs()
    return m
}

@MainActor
private func waitUntilIdle(_ m: AppModel) async {
    try? await Task.sleep(for: .milliseconds(20))
    for _ in 0..<500 where m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
}

@Test @MainActor func refreshKeepsEveryLoadedPageAndASelectionFromPageThree() async {
    let m = await loadedEverything(GatedGh(gate: { _ in false }, override: pagedPRs(pages: 3)))
    let total = m.prs.count
    let onPageThree = m.prs.first { $0.number >= 2000 }!
    m.selection.toggle(onPageThree.id)
    m.focused = onPageThree.id

    m.loadPRs(soft: true)
    await waitUntilIdle(m)
    #expect(m.prs.count == total)  // not collapsed back to page one
    #expect(m.selection.selected == [onPageThree.id])
    #expect(m.focusedPR?.id == onPageThree.id)
    #expect(m.selection.targets(in: m.prs).map(\.id) == [onPageThree.id])
}

@Test @MainActor func aSelectedPRThatDisappearedIsDroppedFromTheSelectionAndFocus() async {
    let gone = Box<Set<Int>>([])
    let m = await loadedEverything(GatedGh(gate: { _ in false }, override: pagedPRs(pages: 3, gone: gone)))
    let victim = m.prs.first { $0.number >= 1000 && $0.number < 2000 }!
    let keeper = m.prs[0]
    m.selection.toggle(victim.id); m.selection.toggle(keeper.id)
    m.focused = victim.id

    gone.set([victim.number])  // merged by someone else
    m.loadPRs(soft: true)
    await waitUntilIdle(m)
    #expect(m.selection.selected == [keeper.id])  // count, targets and detail agree with the list
    #expect(m.focused == nil)
    #expect(!m.prs.contains { $0.id == victim.id })
}

@Test @MainActor func aFilterThatMatchesNothingExplainsItself() async {
    let m = await loadedEverything(GatedGh(gate: { _ in false }, override: pagedPRs(pages: 1)))
    #expect(m.listEmptyState == nil)
    m.filter = "author:nobody-has-this-login"
    #expect(!m.prs.isEmpty && m.visiblePRs.isEmpty)
    #expect(m.listEmptyState == .noMatches)

    m.filter = ""
    m.prs = []
    #expect(m.listEmptyState == .noOpenPRs)
    m.filter = "anything"
    #expect(m.listEmptyState == .noOpenPRs)  // nothing to filter, so it is not a filter problem
}
