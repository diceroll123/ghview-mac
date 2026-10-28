import Foundation
import Testing
@testable import GHView
@testable import GHCore

@MainActor
private func modelWithPRs(_ gh: GatedGh) async -> AppModel {
    let model = AppModel()
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("a")])
    model.selectedSourceIDs = ["a"]
    model.selectedRepo = RepoId(owner: "diceroll123", name: "ghview")
    gh.setGateEnabled(false)
    model.loadPRs()
    for _ in 0..<500 where model.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    for _ in 0..<500 where model.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    gh.setGateEnabled(true)
    return model
}

private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

@Test @MainActor func aDraftSurvivesVisitingAnotherPR() async {
    let model = await modelWithPRs(GatedGh { _ in false })
    let (a, b) = (model.prs[0], model.prs[1])
    model.setDraftText("half-written thought", for: a.id)

    model.focused = b.id  // look at another PR
    model.setDraftText("something for b", for: b.id)
    model.focused = a.id
    #expect(model.draftText(for: a.id) == "half-written thought")
    #expect(model.draftText(for: b.id) == "something for b")

    model.setDraftText("", for: b.id)
    #expect(model.drafts[b.id] == nil)  // emptied drafts do not pile up
}

@Test @MainActor func aLatePostCompletionOnlyTouchesItsOwnDraft() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b) = (model.prs[0], model.prs[1])
    model.setDraftText("for a", for: a.id)

    let post = Task { await model.postDraft(for: a) }
    await gh.waitForRequest("pr:comment:\(a.number)")
    #expect(model.drafts[a.id]?.posting == true)
    model.focused = b.id  // navigate away while the request is out
    model.setDraftText("typing in b", for: b.id)

    await gh.release("pr:comment:\(a.number)")
    await post.value
    #expect(model.drafts[a.id] == nil)  // a's draft is cleared by a's own success
    #expect(model.draftText(for: b.id) == "typing in b")
    #expect(model.drafts[b.id]?.error == nil)
}

@Test @MainActor func aFailedPostKeepsItsDraftAndShowsTheErrorOnlyThere() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let (a, b) = (model.prs[0], model.prs[1])
    model.setDraftText("for a", for: a.id)
    model.setDraftText("for b", for: b.id)

    let post = Task { await model.postDraft(for: a) }
    await gh.waitForRequest("pr:comment:\(a.number)")
    await gh.release("pr:comment:\(a.number)", fail: true)
    await post.value
    #expect(model.drafts[a.id]?.text == "for a")
    #expect(model.drafts[a.id]?.error != nil)
    #expect(model.drafts[a.id]?.posting == false)
    #expect(model.drafts[b.id] == CommentDraft(text: "for b"))
}

@Test @MainActor func aSecondPostWhileOneIsRunningIsIgnored() async {
    let gh = GatedGh { $0.hasPrefix("pr:") }
    let model = await modelWithPRs(gh)
    let a = model.prs[0]
    model.setDraftText("once", for: a.id)

    let first = Task { await model.postDraft(for: a) }
    await gh.waitForRequest("pr:comment:\(a.number)")
    await model.postDraft(for: a)
    await settle()
    #expect(await gh.requests().filter { $0 == "pr:comment:\(a.number)" }.count == 1)
    await gh.release("pr:comment:\(a.number)")
    await first.value
}
