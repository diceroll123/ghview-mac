import Foundation
import Testing
@testable import GHView
@testable import GHCore

private func isolatedDefaults() -> UserDefaults {
    let name = "ghview-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func model(_ defaults: UserDefaults = isolatedDefaults()) -> AppModel {
    AppModel(defaults: defaults, countsURL: FileManager.default.temporaryDirectory.appendingPathComponent("counts-\(UUID().uuidString).json"))
}

private func viewerJSON() throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GHCoreTests/Fixtures/viewer.json"))
}

/// Fails every viewer request until `up` is set.
private func flaky(_ up: Box<Bool>, failure: GhError) -> GatedGh {
    GatedGh(gate: { _ in false }, override: { args in
        if args.contains(where: { $0.contains("viewer { login") }) {
            if !up.get() { throw failure }
            return try viewerJSON()
        }
        return nil
    })
}

@Test @MainActor func aFailedStartupRecoversOnRetryWithoutRestarting() async {
    let up = Box(false)
    let gh = flaky(up, failure: GhError(args: [], status: 1, stderr: "dial tcp: lookup api.github.com: no such host"))
    let m = model()
    await m.start(runner: { gh })
    #expect(m.connection == .problem(.offline))
    #expect(m.viewer == nil && !m.isStarting)

    up.set(true)
    m.refresh()                                       // the ordinary refresh control reconnects
    for _ in 0..<2500 where m.connection != .connected { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(m.connection == .connected)
    #expect(m.viewer != nil)
    #expect(!m.sources.isEmpty)
}

@Test @MainActor func missingCLIAndExpiredAuthAreToldApart() async {
    let missing = model()
    await missing.start(runner: { throw GhError(args: [], status: 127, stderr: "gh not found; install it from https://cli.github.com") })
    #expect(missing.connection == .problem(.missingCLI))
    #expect(ConnectionProblem.missingCLI.advice.contains("brew install gh"))

    let up = Box(false)
    let expired = model()
    await expired.start(runner: { flaky(up, failure: GhError(args: [], status: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login")) })
    #expect(expired.connection == .problem(.notSignedIn))
    #expect(ConnectionProblem.notSignedIn.advice.contains("gh auth login"))
    #expect(ConnectionProblem.classify(GhError(args: [], status: 124, stderr: "stopped")) == .offline)
    #expect(ConnectionProblem.classify(GhError(args: [], status: 1, stderr: "HTTP 401: Bad credentials")) == .notSignedIn)
}

@Test @MainActor func savedSourcesAreAvailableEvenWhenGitHubIsNot() async {
    let defaults = isolatedDefaults()
    SourceCatalog.seeded(from: [.org("acme"), .user("me")]).save(to: defaults)
    let up = Box(false)
    let m = model(defaults)
    await m.start(runner: { flaky(up, failure: GhError(args: [], status: 1, stderr: "dial tcp: no such host")) })
    #expect(m.connection == .problem(.offline))
    #expect(m.allSources.map(\.name).sorted() == ["acme", "me"])      // loaded from disk, not from the network
    #expect(m.selectedSourceIDs.isEmpty)                              // nothing is loaded for them until connected
}

@Test @MainActor func resettingSourcesWhileDisconnectedIsANoOp() async {
    let m = model()
    let before = m.catalog
    m.resetSources()
    #expect(m.catalog == before)                                     // no viewer to reseed from yet
}

@Test @MainActor func concurrentStartAttemptsRunOnce() async {
    let up = Box(true)
    let gh = flaky(up, failure: GhError(args: [], status: 1, stderr: ""))
    let m = model()
    async let a: Void = m.start(runner: { gh })
    async let b: Void = m.start(runner: { gh })
    _ = await (a, b)
    #expect(await gh.requests().filter { $0.contains("viewer { login") }.count == 1)
    #expect(m.connection == .connected)
}

@Test @MainActor func startingAgainOnceConnectedLeavesTheUsersPlaceAlone() async {
    let gh = flaky(Box(true), failure: GhError(args: [], status: 1, stderr: ""))
    let m = model()
    await m.start(runner: { gh })
    #expect(m.connection == .connected)
    m.selectedSourceIDs = ["acme"]
    m.filter = "label:bug"

    await m.start(runner: { gh })                     // e.g. a window appearing again
    #expect(m.selectedSourceIDs == ["acme"] && m.filter == "label:bug")
    #expect(await gh.requests().filter { $0.contains("viewer { login") }.count == 1)
}
