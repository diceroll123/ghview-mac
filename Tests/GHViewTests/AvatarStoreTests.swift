import AppKit
import Foundation
import Testing
@testable import GHCore
@testable import GHView

/// Stand-in image bytes; the tests decode them with a closure that records which bytes an image came from.
private func png(_ shade: UInt8) -> Data { Data(repeating: shade, count: 16) }

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
}

private final class Net: @unchecked Sendable {
    private let lock = NSLock()
    var fail = false
    var shade: UInt8 = 10
    private(set) var policies: [URLRequest.CachePolicy] = []
    private(set) var tokens: [String?] = []
    var networkCalls: Int { lock.withLock { policies.filter { $0 == .reloadRevalidatingCacheData }.count } }
    private func record(_ policy: URLRequest.CachePolicy, _ token: String?) -> (Bool, UInt8) {
        lock.withLock {
            policies.append(policy); tokens.append(token); return (fail, shade)
        }
    }
    func fetch(_ url: URL, _ policy: URLRequest.CachePolicy, _ token: String?) async throws -> (Data, Int) {
        let (failing, s) = record(policy, token)
        if policy == .returnCacheDataDontLoad { throw URLError(.resourceUnavailable) }  // nothing on disk
        if failing { throw URLError(.notConnectedToInternet) }
        return (png(s), 200)
    }
}

private let url = URL(string: "https://avatars.example/u/1")!

@MainActor
private func store(_ net: Net, _ clock: Clock, limit: Int = 500) -> AvatarStore {
    // Each decoded image remembers which bytes it came from, so tests can tell one avatar from another.
    AvatarStore(
        fetch: { try await net.fetch($0, $1, $2) }, now: { clock.date },
        decode: { data in
            let image = NSImage(size: NSSize(width: 1, height: 1))
            image.accessibilityDescription = String(data.hashValue)
            return image
        }, limit: limit)
}

@Test @MainActor func aFailedAvatarRecoversAfterTheRetryInterval() async {
    let net = Net(), clock = Clock()
    let s = store(net, clock)
    net.fail = true
    await s.load(url)
    #expect(s.image(for: url) == nil && net.networkCalls == 1)

    net.fail = false
    await s.load(url)  // too soon: no new request
    #expect(net.networkCalls == 1 && s.image(for: url) == nil)

    clock.advance(AvatarStore.firstRetry + 1)
    await s.load(url)
    #expect(net.networkCalls == 2)
    #expect(s.image(for: url) != nil)
}

@Test @MainActor func retryDelaysDoubleUpToACap() async {
    let net = Net(), clock = Clock()
    let s = store(net, clock)
    net.fail = true
    await s.load(url)  // first failure: retry after 30 s
    clock.advance(31)
    await s.load(url)  // second failure: retry after 60 s
    clock.advance(31)
    await s.load(url)
    #expect(net.networkCalls == 2)  // 31 s is not enough any more
    clock.advance(30)
    await s.load(url)
    #expect(net.networkCalls == 3)
}

@Test @MainActor func aChangedAvatarRefreshesOnceTheCopyIsStale() async {
    let net = Net(), clock = Clock()
    let s = store(net, clock)
    await s.load(url)
    let first = s.image(for: url)
    #expect(first != nil && net.networkCalls == 1)

    clock.advance(3600)
    net.shade = 200  // the user changed their picture
    await s.load(url)
    #expect(net.networkCalls == 1)  // still fresh: no request

    clock.advance(24 * 3600)
    await s.load(url)
    #expect(net.networkCalls == 2)
    #expect(s.image(for: url)?.accessibilityDescription != first?.accessibilityDescription)
}

@Test @MainActor func aCachedCopyIsShownAndThenRevalidated() async {
    let cached = png(50)
    let calls = LockedPolicies()
    let s = AvatarStore(
        fetch: { _, policy, _ in
            calls.add(policy)
            if policy == .returnCacheDataDontLoad { return (cached, 200) }
            return (png(90), 200)
        }, decode: { _ in NSImage(size: NSSize(width: 1, height: 1)) })
    await s.load(url)
    #expect(calls.policies == [.returnCacheDataDontLoad, .reloadRevalidatingCacheData])
    #expect(s.image(for: url) != nil)
}

private final class LockedPolicies: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [URLRequest.CachePolicy] = []
    func add(_ p: URLRequest.CachePolicy) { lock.withLock { all.append(p) } }
    var policies: [URLRequest.CachePolicy] { lock.withLock { all } }
}

@Test @MainActor func theImageCacheIsBoundedAndKeepsTheRecentlyUsed() async {
    let net = Net(), clock = Clock()
    let s = store(net, clock, limit: 3)
    let urls = (1...5).map { URL(string: "https://avatars.example/u/\($0)")! }
    for u in urls[0...2] { await s.load(u) }
    _ = s.image(for: urls[0])  // used again: now the most recent
    await s.load(urls[3])
    await s.load(urls[4])
    #expect(s.cachedCount == 3)
    #expect(s.image(for: urls[0]) != nil)  // survived because it was in use
    #expect(s.image(for: urls[4]) != nil && s.image(for: urls[3]) != nil)
    #expect(s.image(for: urls[1]) == nil)
}

@Test @MainActor func concurrentLoadsOfOneAvatarShareARequest() async {
    let net = Net(), clock = Clock()
    let s = store(net, clock)
    async let a: Void = s.load(url)
    async let b: Void = s.load(url)
    _ = await (a, b)
    #expect(net.networkCalls == 1)
}

private struct TokenGh: GhRunner {
    func run(_ args: [String], stdin: Data?, cwd: URL?) async throws -> Data { Data("sso-token-123\n".utf8) }
}

@Test @MainActor func configuredAuthAttachesTheGhTokenToRequests() async {
    let net = Net(), clock = Clock()
    let s = store(net, clock)
    s.configureAuth(gh: TokenGh())
    await s.load(url)
    #expect(net.tokens == ["sso-token-123", "sso-token-123"])  // so an avatar behind SAML SSO loads like any other gh call
}
