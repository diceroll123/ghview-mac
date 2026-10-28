import Foundation
import Testing
@testable import GHView
@testable import GHCore

private let repoA = RepoId(owner: "a", name: "a-repo")
private let repoB = RepoId(owner: "a", name: "b-repo")

/// A model viewing `repoA` with its first page loaded; the fixture reports a further page.
@MainActor
private func loadedModel(_ gh: GatedGh) async -> AppModel {
    let model = AppModel()
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("a")])
    model.selectedSourceIDs = ["a"]
    model.selectedRepo = repoA
    gh.setGateEnabled(false)
    model.loadPRs()
    await gh.waitForRequest("prs:a/a-repo")
    for _ in 0..<500 where model.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    gh.setGateEnabled(true)
    return model
}

private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

@Test @MainActor func loadMoreCannotOvertakeARefresh() async {
    let gh = GatedGh { $0.hasPrefix("prs:") }
    let model = await loadedModel(gh)
    let firstPage = model.prs.map(\.id)
    #expect(model.hasMorePRs && !firstPage.isEmpty)

    model.loadPRs(soft: true)
    await gh.waitForRequest("prs:a/a-repo", count: 2)
    model.loadPRs(more: true)  // the Load more button is still on screen during a refresh
    await settle()
    #expect(await gh.requests().filter { $0 == "prs:a/a-repo" }.count == 2)  // no third request

    await gh.release("prs:a/a-repo")
    await settle()
    #expect(model.prs.map(\.id) == firstPage)
    #expect(!model.prsLoading && !model.prsLoadingMore)
}

@Test @MainActor func repeatedLoadMoreRunsOnePageAtATimeAndNeverDuplicates() async {
    let gh = GatedGh { $0.hasPrefix("prs:") }
    let model = await loadedModel(gh)
    let count = model.prs.count

    model.loadPRs(more: true)
    await gh.waitForRequest("prs:a/a-repo", count: 2)
    model.loadPRs(more: true)
    model.loadPRs(more: true)
    await settle()
    #expect(await gh.requests().filter { $0 == "prs:a/a-repo" }.count == 2)

    await gh.release("prs:a/a-repo")  // the fixture serves the same page again
    await settle()
    #expect(Set(model.prs.map(\.id)).count == model.prs.count)
    #expect(model.prs.count == count)
    #expect(!model.prsLoadingMore)
}

@Test @MainActor func aFailedRefreshKeepsPagingConsistentWithTheList() async {
    let gh = GatedGh { $0.hasPrefix("prs:") }
    let model = await loadedModel(gh)
    let ids = model.prs.map(\.id), cursor = model.prCursor

    model.loadPRs(soft: true)
    await gh.waitForRequest("prs:a/a-repo", count: 2)
    await gh.release("prs:a/a-repo", fail: true)
    await settle()
    #expect(model.prs.map(\.id) == ids)
    #expect(model.prCursor == cursor)
    #expect(model.hasMorePRs)  // the old pages are still on screen, so more can still be fetched
    #expect(model.loadFailed)
}

@Test @MainActor func switchingRepoDisablesLoadMoreUntilTheFirstPageArrives() async {
    let gh = GatedGh { $0.hasPrefix("prs:") }
    let model = await loadedModel(gh)
    #expect(model.hasMorePRs)

    model.selectedRepo = repoB
    model.loadPRs()
    await gh.waitForRequest("prs:a/b-repo")
    #expect(!model.hasMorePRs && model.prs.isEmpty)
    model.loadPRs(more: true)
    await settle()
    #expect(await gh.requests().filter { $0 == "prs:a/b-repo" }.count == 1)

    await gh.release("prs:a/b-repo")
    await settle()
    #expect(model.hasMorePRs && !model.prs.isEmpty)
}
