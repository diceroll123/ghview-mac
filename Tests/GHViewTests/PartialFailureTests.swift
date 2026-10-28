import Foundation
import Testing
@testable import GHView
@testable import GHCore

private let rate = #"{"remaining":4000,"limit":5000,"cost":1,"resetAt":"2026-10-27T00:00:00Z"}"#

/// Search answers for every org except `broken`, which fails until `fixed` is set.
private func searchGh(broken: String, fixed: Box<Bool>) -> GatedGh {
    GatedGh(
        gate: { _ in false },
        override: { args in
            guard let q = args.first(where: { $0.hasPrefix("q=") }) else { return nil }
            if q.contains("org:\(broken)"), !fixed.get() {
                throw GhError(args: args, status: 1, stderr: "Resource protected by organization SAML enforcement")
            }
            return nil
        })
}

@Test @MainActor func healthySourcesStayUsableWhileOneFailsAndRetryFillsItIn() async {
    let fixed = Box(false)
    let gh = searchGh(broken: "b", fixed: fixed)
    let m = AppModel()
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.org("a"), .org("b")])
    m.selectedSourceIDs = ["a", "b"]
    m.loadPRs()
    for _ in 0..<500 where m.prs.isEmpty { try? await Task.sleep(for: .milliseconds(2)) }
    for _ in 0..<500 where m.prsLoading { try? await Task.sleep(for: .milliseconds(2)) }

    #expect(!m.prs.isEmpty)  // a's PRs are there
    #expect(m.prFailures.map(\.scope) == ["org:b"])
    #expect(m.error == nil && !m.loadFailed)
    let before = m.prs.count

    fixed.set(true)
    m.retryFailedSources()
    for _ in 0..<500 where !m.prFailures.isEmpty || m.prsLoadingMore { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.prFailures.isEmpty)
    #expect(m.prs.count >= before)
}

@Test @MainActor func oneSourceWhoseReposCannotBeListedDoesNotHideTheOthers() async {
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            guard let login = args.first(where: { $0.hasPrefix("login=") }) else { return nil }
            if login == "login=b" {
                throw GhError(args: args, status: 1, stderr: "Could not resolve to an Organization with the login of 'b'")
            }
            return nil
        })
    let m = AppModel()
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.org("a"), .org("b")])
    await m.loadRepos(for: m.catalog.allSources)
    #expect(m.repos.map(\.id.name) == ["a-repo"])
    #expect(m.repoFailures.keys.sorted() == ["b"])
    #expect(m.error == nil)

    // Once b works again, retrying fetches only b and merges its repos in.
    let healed = GatedGh(gate: { _ in false })
    m.connect(healed)
    await m.retryFailedRepos()
    #expect(m.repos.map(\.id.name).sorted() == ["a-repo", "b-repo"])
    #expect(m.repoFailures.isEmpty)
    #expect(await healed.requests() == ["repos:b"])
}

@Test @MainActor func whenEverySourceFailsEachOneIsReportedOnItsOwnRow() async {
    let gh = GatedGh(
        gate: { _ in false },
        override: { args in
            if args.contains(where: { $0.hasPrefix("login=") }) { throw GhError(args: args, status: 1, stderr: "boom") }
            return nil
        })
    let m = AppModel()
    m.connect(gh)
    m.catalog = SourceCatalog.seeded(from: [.org("a"), .org("b")])
    await m.loadRepos(for: m.catalog.allSources)
    #expect(m.repos.isEmpty)
    #expect(m.repoFailures == ["a": "boom", "b": "boom"])  // shown under each source, not as an alert
    #expect(m.error == nil)
}
