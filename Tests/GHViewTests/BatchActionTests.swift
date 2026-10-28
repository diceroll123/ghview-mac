import Foundation
import Testing
@testable import GHView
@testable import GHCore

/// A model with the fixture's open PRs loaded and push access to their repository.
@MainActor
private func modelWithPRs(_ gh: GatedGh) async -> AppModel {
    let model = AppModel()
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("a")])
    model.selectedSourceIDs = ["a"]
    model.selectedRepo = RepoId(owner: "diceroll123", name: "ghview")
    model.viewer = Viewer(login: "me", orgs: [])
    gh.setGateEnabled(false)
    model.loadPRs()
    for _ in 0..<500 where model.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    for _ in 0..<500 where model.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    gh.setGateEnabled(true)
    model.repos = Set(model.prs.map(\.repo)).map {
        RepoInfo(id: $0, language: nil, pushedAt: nil, stars: 0, openPRs: 0, isArchived: false, isPrivate: false,
                 canPush: true, allowAutoMerge: true, hasIssues: true)
    }
    return model
}

private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

private func tag(_ pr: PR, _ sub: String = "close") -> String { "pr:\(sub):\(pr.number)" }

@Test @MainActor func aDoubleSubmitRunsTheActionOnce() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let pr = model.prs[0]

    model.perform(.close, on: [pr])
    await gh.waitForRequest(tag(pr))
    #expect(model.unavailableReason(.close, for: [pr]) != nil)   // the button is disabled while it runs
    model.perform(.close, on: [pr])
    model.perform(.close, on: [pr])
    await settle()
    #expect(await gh.requests().filter { $0 == tag(pr) }.count == 1)

    await gh.release(tag(pr))
    await settle()
    #expect(model.busy.isEmpty)
}

@Test @MainActor func batchProgressTracksCompletionAndClearsWhenDone() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b) = (model.prs[0], model.prs[1])

    model.perform(.close, on: [a, b], confirmed: true)
    await gh.waitForRequest(tag(a)); await gh.waitForRequest(tag(b))
    #expect(model.batchProgress == BatchProgress(done: 0, total: 2))

    await gh.release(tag(a))
    await settle()
    #expect(model.batchProgress == BatchProgress(done: 1, total: 2))

    await gh.release(tag(b))
    await settle()
    #expect(model.batchProgress == nil)
}

@Test @MainActor func aSelectionMadeWhileABatchRunsSurvivesIt() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b, c) = (model.prs[0], model.prs[1], model.prs[2])
    model.selection.toggle(a.id); model.selection.toggle(b.id)

    model.perform(.close, on: [a, b], confirmed: true)
    await gh.waitForRequest(tag(a)); await gh.waitForRequest(tag(b))
    #expect(model.isBusy([a]) && model.isBusy([b]))
    model.selection.clear()                         // the user moved on and picked something else
    model.selection.toggle(c.id)

    await gh.release(tag(a)); await gh.release(tag(b), fail: true)
    await settle()
    #expect(model.busy.isEmpty)
    #expect(model.selection.selected == [c.id])     // untouched by the finished batch
}

@Test @MainActor func everyTargetStaysSelectedAfterABatchWhetherOrNotItFailed() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b) = (model.prs[0], model.prs[1])
    model.selection.toggle(a.id); model.selection.toggle(b.id)

    model.perform(.close, on: [a, b], confirmed: true)
    await gh.waitForRequest(tag(a)); await gh.waitForRequest(tag(b))
    await gh.release(tag(a)); await gh.release(tag(b), fail: true)
    await settle()
    #expect(model.selection.selected == [a.id, b.id])
}

@Test @MainActor func aFinishedActionDoesNotReloadTheList() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b) = (model.prs[0], model.prs[1])
    model.selection.toggle(a.id); model.selection.toggle(b.id)
    await settle()   // let the initial load finish its follow-up requests
    let before = await gh.requests().filter { !$0.hasPrefix("pr:") }

    model.perform(.close, on: [a, b], confirmed: true)
    await gh.waitForRequest(tag(a)); await gh.waitForRequest(tag(b))
    await gh.release(tag(a)); await gh.release(tag(b))
    await settle()
    #expect(model.busy.isEmpty)
    #expect(model.selection.selected == [a.id, b.id])
    #expect(await gh.requests().filter { !$0.hasPrefix("pr:") } == before)
}

@Test @MainActor func bulkMergeAndCloseAskForConfirmationListingTheTargets() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b) = (model.prs[0], model.prs[1])

    model.perform(.close, on: [a, b])
    let pending = try? #require(model.pendingConfirmation)
    #expect(pending?.targets.map(\.id) == [a.id, b.id])
    #expect(pending?.message.contains("diceroll123/ghview#\(a.number)") == true)
    #expect(await gh.requests().filter { $0.hasPrefix("pr:") }.isEmpty)   // nothing runs before the user agrees

    model.perform(.merge, on: [a])                   // a single PR needs no confirmation
    await gh.waitForRequest(tag(a, "merge"))
}

@Test @MainActor func hiddenSelectionIsCountedAndCanBeDropped() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b) = (model.prs[0], model.prs[1])
    model.selection.toggle(a.id); model.selection.toggle(b.id)
    #expect(model.hiddenSelectedCount == 0)

    model.filter = "author:nobody-has-this-login"
    #expect(model.hiddenSelectedCount == 2)
    model.selection.deselect(model.selection.hidden(from: model.visiblePRs.map(\.id)))
    #expect(model.selection.count == 0)
}

// MARK: merge controls only appear when merging is possible

@MainActor
private func withRepo(_ model: AppModel, canPush: Bool, autoMerge: Bool = true) {
    model.repos = Set(model.prs.map(\.repo)).map {
        RepoInfo(id: $0, language: nil, pushedAt: nil, stars: 0, openPRs: 0, isArchived: false, isPrivate: false,
                 canPush: canPush, allowAutoMerge: autoMerge, hasIssues: true)
    }
}

@Test @MainActor func mergeControlsAreOfferedOnlyWhenTheSelectionCanBeMerged() async {
    let model = await modelWithPRs(GatedGh { $0.hasPrefix("pr:") })
    let pr = model.prs[0]
    #expect(model.offers(.merge, for: [pr]) && model.offers(.autoMerge, for: [pr]))     // push access, open, not a draft

    withRepo(model, canPush: false)
    #expect(!model.offers(.merge, for: [pr]) && !model.offers(.autoMerge, for: [pr]))   // no push access: nothing to show
    #expect(!model.offers(.disableAutoMerge, for: [pr]))

    withRepo(model, canPush: true, autoMerge: false)
    #expect(model.offers(.merge, for: [pr]) && !model.offers(.autoMerge, for: [pr]))    // the repo has auto-merge off

    var draft = pr; draft.isDraft = true
    #expect(!model.offers(.merge, for: [draft]) && !model.offers(.autoMerge, for: [draft]))
    var closed = pr; closed.isOpen = false
    #expect(!model.offers(.merge, for: [closed]))
}

@Test @MainActor func aMixedSelectionOffersMergeIfAnyOfItCanBeMerged() async {
    let model = await modelWithPRs(GatedGh { $0.hasPrefix("pr:") })
    var draft = model.prs[0]; draft.isDraft = true
    let ok = model.prs[1]
    #expect(model.offers(.merge, for: [draft, ok]))
    #expect(!model.offers(.merge, for: [draft]))
}

@Test @MainActor func controlsStayWhileTheAnswerIsStillComing() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let pr = model.prs[0]

    model.repos = []                                               // permissions not loaded yet: not a "no"
    #expect(model.unavailableReason(.merge, for: [pr]) != nil)
    #expect(model.offers(.merge, for: [pr]))

    withRepo(model, canPush: true)
    model.perform(.close, on: [pr], confirmed: true)               // busy: another action is running on it
    await gh.waitForRequest("pr:close:\(pr.number)")
    #expect(model.offers(.merge, for: [pr]))
    await gh.release("pr:close:\(pr.number)")
}
