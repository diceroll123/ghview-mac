import Foundation
import Testing
@testable import GHView
@testable import GHCore

private let rate = #"{"remaining":4000,"limit":5000,"cost":1,"resetAt":"2026-10-27T00:00:00Z"}"#

private func repoNode(_ owner: String, _ name: String, perm: String = "WRITE") -> String {
    #"{"name":"\#(name)","owner":{"login":"\#(owner)"},"primaryLanguage":null,"pushedAt":"2026-10-26T20:34:12Z","stargazerCount":0,"isArchived":false,"isPrivate":false,"viewerPermission":"\#(perm)","autoMergeAllowed":true,"hasIssuesEnabled":true,"pullRequests":{"totalCount":0}}"#
}

/// Serves `total` repos named r0, r1, ... in pages of the requested size.
private func pagedRepos(total: Int) -> @Sendable ([String]) -> Data? {
    { args in
        guard args.contains(where: { $0.hasPrefix("login=") }) else { return nil }
        let first = Int(args.first { $0.hasPrefix("first=") }.map { String($0.dropFirst(6)) } ?? "100") ?? 100
        let start = Int(args.first { $0.hasPrefix("after=") }.map { String($0.dropFirst(6)) } ?? "0") ?? 0
        let end = min(start + first, total)
        let nodes = (start..<end).map { repoNode("big", "r\($0)") }.joined(separator: ",")
        return Data(
            #"{"data":{"rateLimit":\#(rate),"repositoryOwner":{"repositories":{"pageInfo":{"hasNextPage":\#(end < total),"endCursor":"\#(end)"},"nodes":[\#(nodes)]}}}}"#
                .utf8)
    }
}

@Test @MainActor func everyRepoPastThreeHundredIsReachable() async {
    let gh = GatedGh(gate: { _ in false }, override: pagedRepos(total: 450))
    let model = AppModel()
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("big")])
    await model.loadRepos(for: model.catalog.allSources)
    #expect(model.repos.count == 450)
    #expect(model.repos(in: .org("big")).last?.id.name == "r449")
    #expect(!model.isTruncated(.org("big")))
}

@Test @MainActor func enumerationStopsAtTheCapAndSaysSo() async {
    let total = AppModel.maxReposPerSource + 150
    let gh = GatedGh(gate: { _ in false }, override: pagedRepos(total: total))
    let model = AppModel()
    model.connect(gh)
    model.catalog = SourceCatalog.seeded(from: [.org("big")])
    await model.loadRepos(for: model.catalog.allSources)
    #expect(model.repos.count >= AppModel.maxReposPerSource && model.repos.count < total)
    #expect(model.isTruncated(.org("big")))
}

private func infoOverride(permission: String?) -> @Sendable ([String]) -> Data? {
    { args in
        guard args.contains(where: { $0.hasPrefix("o0=") }) else { return nil }
        guard let permission else { return Data("{}".utf8) }  // no data: the request fails
        return Data(#"{"data":{"rateLimit":\#(rate),"r0":\#(repoNode("diceroll123", "ghview", perm: permission))}}"#.utf8)
    }
}

@MainActor
private func modelShowingPRsWithoutRepoList(_ gh: GatedGh) async -> AppModel {
    let model = AppModel()
    model.connect(gh)
    model.viewer = Viewer(login: "me", orgs: [])
    model.catalog = SourceCatalog.seeded(from: [.org("a")])
    model.selectedSourceIDs = ["a"]
    model.selectedRepo = RepoId(owner: "diceroll123", name: "ghview")
    model.loadPRs()
    for _ in 0..<500 where model.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    for _ in 0..<500 where model.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }
    return model
}

@Test @MainActor func aPRInAnUnlistedRepoGetsItsRealPermissions() async {
    let gh = GatedGh(gate: { _ in false }, override: infoOverride(permission: "WRITE"))
    let model = await modelShowingPRsWithoutRepoList(gh)
    let pr = model.prs[0]
    #expect(model.repos.isEmpty)

    // Loading the PRs also fetches the permissions the repo list does not cover.
    for _ in 0..<500 where model.repoInfo(for: pr.repo) == nil { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(model.repoInfo(for: pr.repo)?.canPush == true)
    #expect(model.unavailableReason(.close, for: [pr]) == nil)
}

@Test @MainActor func aFailedPermissionLookupIsNotReportedAsADenial() async {
    let gh = GatedGh(gate: { _ in false }, override: infoOverride(permission: nil))
    let model = await modelShowingPRsWithoutRepoList(gh)
    let pr = model.prs[0]

    for _ in 0..<500 where !model.failedRepoInfo.contains(pr.repo) { try? await Task.sleep(for: .milliseconds(2)) }
    let reason = model.unavailableReason(.close, for: [pr])
    #expect(reason == "Could not load permissions for diceroll123/ghview")
    #expect(reason?.contains("No push access") == false)
}
