import Foundation
import Testing
@testable import GHView
@testable import GHCore

@MainActor
private func makeModel(_ gh: GatedGh) -> AppModel {
    let model = AppModel()
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("a"), .org("b")])
    return model
}

/// Gives the model's tasks time to apply (or ignore) a response that was just released.
private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

private let repoA = RepoId(owner: "diceroll123", name: "ghview")
private let repoB = RepoId(owner: "diceroll123", name: "other")

@Test @MainActor func aLateRepoLoadIsIgnoredAfterTheDestinationChanged() async {
    let gh = GatedGh { $0.hasPrefix("prs:") || $0.hasPrefix("search:") }
    let model = makeModel(gh)
    model.destination = .repo(repoA)
    model.loadPRs()
    await gh.waitForRequest("prs:diceroll123/ghview")
    #expect(model.prsLoading)

    model.destination = .sources(["b"])  // the user clicks a source instead
    model.loadPRs()
    await gh.waitForRequest("search:org:b")

    await gh.release("prs:diceroll123/ghview")  // the old repo answers first
    await settle()
    #expect(model.prs.isEmpty)
    #expect(model.prsLoading)  // still waiting for what is actually selected

    await gh.release("search:org:b")
    await settle()
    #expect(!model.prs.isEmpty && !model.prsLoading)
}

@Test @MainActor func deselectingEverythingCancelsAPendingLoad() async {
    let gh = GatedGh { $0.hasPrefix("prs:") }
    let model = makeModel(gh)
    model.destination = .repo(repoA)
    model.loadPRs()
    await gh.waitForRequest("prs:diceroll123/ghview")

    model.destination = nil
    model.loadPRs()  // what the view does when the destination changes
    #expect(!model.prsLoading)

    await gh.release("prs:diceroll123/ghview")
    await settle()
    #expect(model.prs.isEmpty && !model.hasMorePRs && !model.prsLoading)
}

@Test @MainActor func aSourceWideLoadIsDroppedWhenAnotherDestinationHasNothingToLoad() async {
    let gh = GatedGh { $0.hasPrefix("search:") }
    let model = makeModel(gh)
    model.destination = .sources(["a"])
    model.loadPRs()
    await gh.waitForRequest("search:org:a")
    #expect(model.prsLoading)

    model.destination = .savedView(UUID())  // a view that no longer exists: nothing to load, but it must still cancel the old load
    model.loadPRs()
    #expect(!model.prsLoading)

    await gh.release("search:org:a")
    await settle()
    #expect(model.prs.isEmpty && !model.hasMorePRs && !model.prsLoading)
}

@Test @MainActor func switchingAwayAndBackIgnoresTheFirstRequest() async {
    let gh = GatedGh { $0.hasPrefix("search:") }
    let model = makeModel(gh)
    model.destination = .sources(["a"])
    model.loadPRs()
    await gh.waitForRequest("search:org:a", count: 1)
    model.destination = .sources(["b"])
    model.loadPRs()
    await gh.waitForRequest("search:org:b")
    model.destination = .sources(["a"])
    model.loadPRs()
    await gh.waitForRequest("search:org:a", count: 2)

    await gh.release("search:org:a")  // the first A finishes, but a newer request owns the screen
    await settle()
    #expect(model.prs.isEmpty && model.prsLoading)

    await gh.release("search:org:b")
    await settle()
    #expect(model.prs.isEmpty && model.prsLoading)

    await gh.release("search:org:a")
    await settle()
    #expect(!model.prs.isEmpty && !model.prsLoading)
}

@Test @MainActor func anOlderRepoAnswerNeverReplacesTheSelectedRepoLoad() async {
    let gh = GatedGh { $0.hasPrefix("prs:") }
    let model = makeModel(gh)
    model.destination = .repo(repoA)
    model.loadPRs()
    await gh.waitForRequest("prs:diceroll123/ghview")
    model.destination = .repo(repoB)
    model.loadPRs()  // a different repo supersedes it
    await gh.waitForRequest("prs:diceroll123/other")

    await gh.release("prs:diceroll123/ghview")  // the old repo answers first
    await settle()
    #expect(model.prs.isEmpty)
    #expect(model.prsLoading)  // still waiting on the repo that is actually selected

    await gh.release("prs:diceroll123/other")
    await settle()
    #expect(!model.prs.isEmpty)
    #expect(!model.prsLoading)
}

@Test @MainActor func theSourceSelectionShimNeverClearsAnotherDestination() {
    let model = makeModel(GatedGh())
    model.destination = .repo(repoA)
    model.selectedSourceIDs = []  // no change: there are no sources selected anyway
    model.selectedSourceIDs.formIntersection(["a"])  // what hiding or deleting a source does
    #expect(model.destination == .repo(repoA))

    model.selectedSourceIDs = ["a", "b"]
    #expect(model.destination == .sources(["a", "b"]) && model.selectedRepo == nil)
    model.selectedRepo = repoB
    #expect(model.destination == .repo(repoB) && model.selectedSourceIDs.isEmpty)
    model.selectedRepo = nil
    #expect(model.destination == nil)
}
