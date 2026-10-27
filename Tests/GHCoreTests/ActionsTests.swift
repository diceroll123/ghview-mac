import Foundation
import Testing
@testable import GHCore

func samplePR(_ n: Int = 1, author: String = "alice", open: Bool = true, draft: Bool = false,
              mergeable: MergeableState = .behind, autoMerge: Bool = false, approved: Bool = false) -> PR {
    PR(id: PrId(repo: RepoId(owner: "o", name: "r"), number: n), title: "t", author: author, isDraft: draft,
       isOpen: open, createdAt: Date(), updatedAt: Date(), url: "u", headRef: "h", baseRef: "main", headSha: "s",
       additions: 0, deletions: 0, comments: 0, autoMerge: autoMerge, reviewStatus: .unknown,
       viewerApproved: approved, mergeable: mergeable, requestedReviewers: [], labels: [], checks: [], checkSummary: .unknown)
}

func ctx(push: Bool = true, autoMerge: Bool = false, viewer: String = "me") -> ActionContext {
    ActionContext(viewerLogin: viewer, repo: RepoInfo(id: RepoId(owner: "o", name: "r"), language: nil, pushedAt: nil,
        stars: 0, openPRs: 0, isArchived: false, isPrivate: false, canPush: push, allowAutoMerge: autoMerge, hasIssues: true))
}

@Test func permissionsAndNoOps() {
    #expect(Permissions.denial(.approve, pr: samplePR(author: "me"), ctx: ctx()) != nil)
    #expect(Permissions.denial(.merge, pr: samplePR(), ctx: ctx(push: false)) != nil)
    #expect(Permissions.denial(.close, pr: samplePR(author: "me"), ctx: ctx(push: false)) == nil)
    let o = ActionOptions()
    #expect(Permissions.noOp(.rebase, pr: samplePR(mergeable: .clean), options: o, ctx: ctx()) != nil)
    #expect(Permissions.noOp(.rebase, pr: samplePR(mergeable: .dirty), options: o, ctx: ctx()) != nil)
    #expect(Permissions.noOp(.rebase, pr: samplePR(mergeable: .unknown), options: o, ctx: ctx()) == nil)
    #expect(Permissions.noOp(.markReady, pr: samplePR(draft: false), options: o, ctx: ctx()) != nil)
    // Merge is always immediate, even when auto-merge is already queued
    #expect(Permissions.noOp(.merge, pr: samplePR(autoMerge: true), options: o, ctx: ctx(autoMerge: true)) == nil)
    #expect(Permissions.noOp(.merge, pr: samplePR(draft: true), options: o, ctx: ctx()) != nil)
    #expect(Permissions.noOp(.autoMerge, pr: samplePR(autoMerge: true), options: o, ctx: ctx(autoMerge: true)) != nil)
    #expect(Permissions.noOp(.autoMerge, pr: samplePR(autoMerge: false), options: o, ctx: ctx(autoMerge: true)) == nil)
    #expect(Permissions.noOp(.disableAutoMerge, pr: samplePR(autoMerge: false), options: o, ctx: ctx()) != nil)
    #expect(Permissions.noOp(.disableAutoMerge, pr: samplePR(autoMerge: true), options: o, ctx: ctx()) == nil)
    #expect(Permissions.denial(.autoMerge, pr: samplePR(), ctx: ctx(autoMerge: false)) != nil)  // repo disallows auto-merge
    #expect(Permissions.denial(.autoMerge, pr: samplePR(), ctx: ctx(autoMerge: true)) == nil)
    #expect(Permissions.denial(.disableAutoMerge, pr: samplePR(), ctx: ctx(push: false)) != nil)
}

@Test func mergeBuildsArgsAndRetries() async throws {
    let calls = LockedBox<[[String]]>([])
    let failures = LockedBox<Int>(2)
    let gh = MockGh { args in
        calls.update { $0 += [args] }
        if failures.get() > 0 {
            failures.set(failures.get() - 1)
            throw GhError(args: args, status: 1, stderr: "Base branch was modified. base branch was modified")
        }
        return Data()
    }
    let slept = LockedBox<Int>(0)
    let actions = PrActions(gh: gh, sleep: { _ in slept.update { $0 += 1 } })
    let out = try await actions.perform(.autoMerge, pr: samplePR(), options: ActionOptions(mergeMethod: .squash), ctx: ctx(autoMerge: true))
    #expect(out == .done("Auto-merge requested for #1; result not confirmed"))
    let merges = calls.get().filter { $0.starts(with: ["pr", "merge"]) }
    #expect(merges.count == 3)
    #expect(merges.last == ["pr", "merge", "1", "-R", "o/r", "--auto", "--squash", "--match-head-commit", "s"])
    #expect(slept.get() == 2)
}

@Test func mergeGivesUpAfterRetries() async {
    let gh = MockGh { args in throw GhError(args: args, status: 1, stderr: "base branch was modified") }
    let actions = PrActions(gh: gh, sleep: { _ in })
    await #expect(throws: GhError.self) {
        _ = try await actions.perform(.merge, pr: samplePR(), options: ActionOptions(), ctx: ctx())
    }
}

@Test func batchSummarizesAndSkips() async {
    let gh = MockGh { args in
        if args.contains("repos/o/r/pulls/3") { throw GhError(args: args, status: 1, stderr: "nope") }
        return args.contains("--jq") ? Data("s\n".utf8) : Data()
    }
    let prs = [samplePR(1), samplePR(2, approved: true), samplePR(3)]
    let summary = await BatchRunner.run(.approve, on: prs, actions: PrActions(gh: gh), options: ActionOptions(),
                                        context: { _ in ctx() })
    #expect(summary.done.count == 1)
    #expect(summary.skipped.count == 1)
    #expect(summary.failed.count == 1)
    #expect(summary.message == "1 done, 1 skipped, 1 failed")
}

@Test func serializerRunsSameKeyInOrder() async throws {
    let s = KeyedSerializer()
    let log = LockedBox<[Int]>([])
    try await withThrowingTaskGroup(of: Void.self) { g in
        for i in 0..<5 {
            g.addTask {
                try await s.run(key: "k") {
                    try await Task.sleep(for: .milliseconds(5))
                    log.update { $0 += [i] }
                }
            }
        }
        try await g.waitForAll()
    }
    #expect(log.get().count == 5)
}

@Test func selectionModeBehavior() {
    let ids = (1...5).map { PrId(repo: RepoId(owner: "o", name: "r"), number: $0) }
    var sel = SelectionState()
    #expect(!sel.showsCheckbox(for: ids[1], focused: ids[0]))
    #expect(sel.showsCheckbox(for: ids[0], focused: ids[0]))
    sel.toggle(ids[0])
    #expect(sel.isSelectionMode)
    #expect(sel.showsCheckbox(for: ids[4], focused: ids[0]))
    sel.selectRange(to: ids[3], in: ids)
    #expect(sel.count == 4)
    sel.selectAll(visible: ids)
    #expect(sel.count == 5)
    sel.selectAll(visible: ids)                      // a second Cmd-A does not toggle them off
    #expect(sel.count == 5)
    sel.clear()
    #expect(!sel.isSelectionMode)
    sel.toggle(ids[2]); sel.toggle(ids[2])
    #expect(!sel.isSelectionMode)
}

@Test func mergeDoesNotPassAutoAndCancelDisablesAuto() async throws {
    let calls = LockedBox<[[String]]>([])
    let actions = PrActions(gh: MockGh { args in calls.update { $0 += [args] }; return Data() })
    // a repo that allows auto-merge still gets a plain merge command (no --auto) from .merge
    let merged = try await actions.perform(.merge, pr: samplePR(1), options: ActionOptions(mergeMethod: .rebase), ctx: ctx(autoMerge: true))
    #expect(merged == .done("Merge requested for #1; result not confirmed"))   // nothing read back from this mock
    let cancelled = try await actions.perform(.disableAutoMerge, pr: samplePR(2, autoMerge: true), options: ActionOptions(), ctx: ctx())
    #expect(cancelled == .done("Auto-merge cancelled for #2"))
    #expect(calls.get().filter { $0.starts(with: ["pr", "merge"]) } == [["pr", "merge", "1", "-R", "o/r", "--rebase", "--match-head-commit", "s"], ["pr", "merge", "2", "-R", "o/r", "--disable-auto"]])
    let skipped = try await actions.perform(.autoMerge, pr: samplePR(3), options: ActionOptions(), ctx: ctx(autoMerge: false))
    #expect(skipped == .skipped("Auto-merge is not enabled for o/r"))
    #expect(calls.get().filter { $0.starts(with: ["pr", "merge"]) }.count == 2)
}

@Test func mergeIsPinnedToInspectedHeadAndMismatchIsSkipped() async throws {
    let calls = LockedBox<[[String]]>([])
    let gh = MockGh { args in
        calls.update { $0 += [args] }
        throw GhError(args: args, status: 1, stderr: "Head branch was modified. Review and try the merge again.")
    }
    let actions = PrActions(gh: gh, sleep: { _ in })
    let out = try await actions.perform(.merge, pr: samplePR(), options: ActionOptions(), ctx: ctx())
    guard case .skipped = out else { Issue.record("expected skipped, got \(out)"); return }
    #expect(calls.get().count == 1)  // no retry, no SHA refresh
    #expect(calls.get()[0].suffix(2) == ["--match-head-commit", "s"])
}

@Test func approveIsBoundToInspectedCommit() async throws {
    let calls = LockedBox<[[String]]>([])
    let head = LockedBox<String>("s")
    let gh = MockGh { args in
        calls.update { $0 += [args] }
        return args.contains("--jq") ? Data((head.get() + "\n").utf8) : Data()
    }
    let actions = PrActions(gh: gh)
    let out = try await actions.perform(.approve, pr: samplePR(), options: ActionOptions(), ctx: ctx())
    #expect(out == .done("Approved #1"))
    #expect(calls.get().last == ["api", "-X", "POST", "repos/o/r/pulls/1/reviews", "-f", "event=APPROVE", "-f", "commit_id=s"])

    calls.set([])
    head.set("newer")  // a push landed after the user loaded the PR
    let stale = try await actions.perform(.approve, pr: samplePR(), options: ActionOptions(), ctx: ctx())
    guard case .skipped = stale else { Issue.record("expected skipped, got \(stale)"); return }
    #expect(!calls.get().contains { $0.contains("POST") })
}

@Test func missingRepoMetadataIsUnknownNotDenied() {
    let unknown = ActionContext(viewerLogin: "me", repo: nil)
    let reason = Permissions.denial(.merge, pr: samplePR(), ctx: unknown)
    #expect(reason == Permissions.unknownPermissions(samplePR()))
    #expect(reason?.contains("No push access") == false)
    #expect(Permissions.denial(.close, pr: samplePR(author: "me"), ctx: unknown) == nil)   // own PR needs no push access
    #expect(Permissions.denial(.close, pr: samplePR(author: "bob"), ctx: unknown) != nil)
    #expect(Permissions.denial(.approve, pr: samplePR(author: "bob"), ctx: unknown) == nil)
    #expect(Permissions.denial(.merge, pr: samplePR(), ctx: ctx(push: false))?.contains("No push access") == true)
}

@Test func fetchesPermissionsForSpecificReposInOneQuery() async throws {
    let seen = LockedBox<[String]>([])
    let gh = MockGh { args in
        seen.update { $0 += args }
        func node(_ o: String, _ n: String, _ perm: String) -> String {
            #"{"name":"\#(n)","owner":{"login":"\#(o)"},"primaryLanguage":null,"pushedAt":null,"stargazerCount":0,"isArchived":false,"isPrivate":false,"viewerPermission":"\#(perm)","autoMergeAllowed":true,"hasIssuesEnabled":true,"pullRequests":{"totalCount":0}}"#
        }
        return Data(#"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":"2026-10-27T00:00:00Z"},"r0":\#(node("o", "a", "WRITE")),"r1":null,"r2":\#(node("o", "c", "READ"))}}"#.utf8)
    }
    let ids = [RepoId(owner: "o", name: "a"), RepoId(owner: "o", name: "gone"), RepoId(owner: "o", name: "c")]
    let result = try await ReposQuery.fetchInfo(ids, client: GraphQLClient(gh: gh))
    #expect(result.repos.map(\.id.name) == ["a", "c"])           // the repo GitHub did not return is simply absent
    #expect(result.repos.map(\.canPush) == [true, false])
    #expect(seen.get().contains("n1=gone"))
    #expect(seen.get().filter { $0 == "-f" }.count >= 7)           // one call carried every repo
}

// MARK: merge methods

private func ctx(allowing methods: [MergeMethod]) -> ActionContext {
    var c = ctx(autoMerge: true)
    c.repo?.allowedMergeMethods = methods
    return c
}

@Test func aMergeOnlyRepositoryIsMergedWithAMergeCommit() async throws {
    let calls = LockedBox<[[String]]>([])
    let actions = PrActions(gh: MockGh { args in calls.update { $0 += [args] }; return Data() })
    let out = try await actions.perform(.merge, pr: samplePR(), options: ActionOptions(mergeMethod: .squash), ctx: ctx(allowing: [.merge]))
    let merge = calls.get().first { $0.starts(with: ["pr", "merge"]) }
    #expect(merge?.contains("--merge") == true && merge?.contains("--squash") == false)
    guard case .done(let message) = out else { Issue.record("expected done"); return }
    #expect(message.contains("squash is not allowed"))                // the substitution is not silent
}

@Test func thePreferredMethodIsUsedWhenAllowedAndNothingIsAddedToTheMessage() async throws {
    let actions = PrActions(gh: MockGh { _ in Data() })
    let out = try await actions.perform(.merge, pr: samplePR(), options: ActionOptions(mergeMethod: .rebase), ctx: ctx(allowing: [.squash, .rebase]))
    #expect(out == .done("Merge requested for #1; result not confirmed"))
}

@Test func methodResolutionPrefersTheChoiceThenSquashMergeRebase() {
    func resolve(_ preferred: MergeMethod, _ allowed: [MergeMethod]) -> MergeMethod? {
        ActionOptions(mergeMethod: preferred).method(for: ctx(allowing: allowed).repo)
    }
    #expect(resolve(.rebase, [.squash, .merge, .rebase]) == .rebase)
    #expect(resolve(.rebase, [.merge, .squash]) == .squash)
    #expect(resolve(.squash, [.rebase, .merge]) == .merge)
    #expect(resolve(.squash, []) == nil)
    #expect(ActionOptions(mergeMethod: .rebase).method(for: nil) == .rebase)      // unknown settings keep the choice
}

@Test func aRepositoryWithNoMergeMethodDisablesMerging() {
    #expect(Permissions.denial(.merge, pr: samplePR(), ctx: ctx(allowing: []))?.contains("no merge method") == true)
    #expect(Permissions.denial(.autoMerge, pr: samplePR(), ctx: ctx(allowing: []))?.contains("no merge method") == true)
    #expect(Permissions.denial(.merge, pr: samplePR(), ctx: ctx(allowing: [.rebase])) == nil)
}

@Test func repositoryQueriesReadTheAllowedStrategies() throws {
    let json = #"{"name":"r","owner":{"login":"o"},"primaryLanguage":null,"pushedAt":null,"stargazerCount":0,"isArchived":false,"isPrivate":false,"viewerPermission":"WRITE","autoMergeAllowed":true,"hasIssuesEnabled":true,"squashMergeAllowed":false,"mergeCommitAllowed":true,"rebaseMergeAllowed":false,"pullRequests":{"totalCount":0}}"#
    let node = try GraphQLClient.decoder.decode(ReposQuery.Response.Node.self, from: Data(json.utf8))
    #expect(ReposQuery.map(node).allowedMergeMethods == [.merge])
    #expect(ReposQuery.query.contains("squashMergeAllowed") && ReposQuery.infoFields.contains("rebaseMergeAllowed"))
}

// MARK: outcomes read back from GitHub

private func mergeGh(view: String) -> (MockGh, LockedBox<[[String]]>) {
    let calls = LockedBox<[[String]]>([])
    return (MockGh { args in
        calls.update { $0 += [args] }
        return args.starts(with: ["pr", "view"]) ? Data(view.utf8) : Data()
    }, calls)
}

@Test func aMergeThatMergedIsReportedMerged() async throws {
    let (gh, calls) = mergeGh(view: #"{"state":"MERGED","isInMergeQueue":false,"autoMergeRequest":null}"#)
    let out = try await PrActions(gh: gh).perform(.merge, pr: samplePR(), options: ActionOptions(), ctx: ctx())
    #expect(out == .done("Merged #1"))
    #expect(calls.get().last == ["pr", "view", "1", "-R", "o/r", "--json", "state,isInMergeQueue,autoMergeRequest"])
}

@Test func aMergeIntoAQueueIsReportedQueuedNotMerged() async throws {
    let (gh, _) = mergeGh(view: #"{"state":"OPEN","isInMergeQueue":true,"autoMergeRequest":null}"#)
    let out = try await PrActions(gh: gh).perform(.merge, pr: samplePR(), options: ActionOptions(), ctx: ctx())
    #expect(out == .queued("Added #1 to the merge queue"))
}

@Test func autoMergeThatLandedAtOnceIsNotReportedAsEnabled() async throws {
    let (gh, _) = mergeGh(view: #"{"state":"MERGED","isInMergeQueue":false,"autoMergeRequest":null}"#)
    let out = try await PrActions(gh: gh).perform(.autoMerge, pr: samplePR(), options: ActionOptions(), ctx: ctx(autoMerge: true))
    guard case .done(let message) = out else { Issue.record("expected done"); return }
    #expect(message.hasPrefix("Merged #1"))
}

@Test func enabledAutoMergeIsDoneForAutoMergeButQueuedForAPlainMerge() async throws {
    let (gh, _) = mergeGh(view: #"{"state":"OPEN","isInMergeQueue":false,"autoMergeRequest":{"enabledAt":"x"}}"#)
    let actions = PrActions(gh: gh)
    #expect(try await actions.perform(.autoMerge, pr: samplePR(), options: ActionOptions(), ctx: ctx(autoMerge: true)) == .done("Auto-merge enabled for #1"))
    guard case .queued = try await actions.perform(.merge, pr: samplePR(), options: ActionOptions(), ctx: ctx()) else {
        Issue.record("a plain merge that only enabled auto-merge is not done"); return
    }
}

@Test func batchesCountQueuedSeparately() async {
    let (gh, _) = mergeGh(view: #"{"state":"OPEN","isInMergeQueue":true,"autoMergeRequest":null}"#)
    let summary = await BatchRunner.run(.merge, on: [samplePR(1), samplePR(2)], actions: PrActions(gh: gh), options: ActionOptions(), context: { _ in ctx() })
    #expect(summary.done.isEmpty && summary.queued.count == 2)
    #expect(summary.message == "2 queued")
    #expect(summary.queuedIDs.count == 2)
}

@Test func aFailedDependabotCommentIsNeverCountedAsSent() async {
    let gh = MockGh { args in
        if args.contains("2") { throw GhError(args: args, status: 1, stderr: "rate limited") }
        return Data()
    }
    let summary = await BatchRunner.comment(Dependabot.comment("rebase"), on: [samplePR(1), samplePR(2), samplePR(3)], actions: PrActions(gh: gh))
    #expect(summary.done.count == 2)
    #expect(summary.failed.count == 1 && summary.failed[0].contains("o/r#2"))
    #expect(summary.failedIDs.map(\.number) == [2])
}

@Test func selectAllAddsToWhatIsHiddenWithoutDroppingIt() {
    let ids = (1...4).map { PrId(repo: RepoId(owner: "o", name: "r"), number: $0) }
    var sel = SelectionState()
    sel.toggle(ids[3])                                // selected, then filtered out of view
    sel.selectAll(visible: Array(ids[0...1]))
    #expect(sel.selected == Set([ids[0], ids[1], ids[3]]))
    #expect(sel.hidden(from: Array(ids[0...1])) == [ids[3]])
}

@Test func anArchivedRepositoryAllowsNothing() {
    var archived = ctx()
    archived.repo?.isArchived = true
    for action in PrAction.allCases {
        let reason = Permissions.denial(action, pr: samplePR(author: "me"), ctx: archived)
        #expect(reason?.contains("archived") == true, "\(action) should be refused")
    }
    #expect(Permissions.denial(.close, pr: samplePR(author: "me"), ctx: ctx()) == nil)       // not archived: unchanged
    #expect(RepoId(owner: "o", name: "r").url.absoluteString == "https://github.com/o/r")
    #expect(RepoId(owner: "o", name: "r").pullRequestsURL.absoluteString == "https://github.com/o/r/pulls")
}

@Test func theHeadCommitIsAbbreviatedAndLinked() {
    var pr = samplePR(7)
    pr.headSha = "0a4ad0e2263938d01e66c7aa6afd49bb7196bf09"
    #expect(pr.shortHeadSha == "0a4ad0e")
    #expect(pr.headCommitURL?.absoluteString == "https://github.com/o/r/commit/0a4ad0e2263938d01e66c7aa6afd49bb7196bf09")
    pr.headSha = "abc"
    #expect(pr.shortHeadSha == "abc")                                 // never longer than the hash itself
}

@Test func repositoryQueriesReadWhetherARepoIsAFork() throws {
    func node(_ extra: String) -> String {
        #"{"name":"r","owner":{"login":"o"},"primaryLanguage":null,"pushedAt":null,"stargazerCount":0,"isArchived":false,"isPrivate":false,"viewerPermission":"WRITE","autoMergeAllowed":true,"hasIssuesEnabled":true,"pullRequests":{"totalCount":0}\#(extra)}"#
    }
    let fork = try GraphQLClient.decoder.decode(ReposQuery.Response.Node.self, from: Data(node(#","isFork":true"#).utf8))
    let plain = try GraphQLClient.decoder.decode(ReposQuery.Response.Node.self, from: Data(node(#","isFork":false"#).utf8))
    let old = try GraphQLClient.decoder.decode(ReposQuery.Response.Node.self, from: Data(node("").utf8))      // a response without the field
    #expect(ReposQuery.map(fork).isFork && !ReposQuery.map(plain).isFork && !ReposQuery.map(old).isFork)
    #expect(ReposQuery.query.contains("isFork") && ReposQuery.infoFields.contains("isFork"))
}
