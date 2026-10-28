import SwiftUI
import AppKit
import GHCore

/// Loads and remembers avatar images.
///
/// - A cached copy is shown at once, then revalidated with GitHub (a cheap conditional request), so a changed
///   avatar shows up without clearing any cache. A copy older than `freshFor` is revalidated again on its next use.
/// - A failed load is retried after a delay that doubles each time (30 s up to 15 min), so a lost connection
///   does not leave avatars missing until the app restarts.
/// - Decoded images are kept in a bounded, least-recently-used cache.
/// - Requests carry the signed-in `gh` token once one is available (`configureAuth`), so an avatar behind SAML
///   SSO - which serves a sign-in page instead of the image to an anonymous request - loads like any other.
@MainActor
@Observable
final class AvatarStore {
    typealias Fetch = @Sendable (URL, URLRequest.CachePolicy, String?) async throws -> (Data, Int)

    static let shared = AvatarStore(fetch: AvatarStore.liveFetch)

    private struct Entry {
        var image: NSImage
        var fetchedAt: Date
    }

    private var images: [URL: Entry] = [:]
    @ObservationIgnored private var lastUsed: [URL: Int] = [:]
    @ObservationIgnored private var useCounter = 0
    @ObservationIgnored private var failures: [URL: (retryAt: Date, attempts: Int)] = [:]
    @ObservationIgnored private var inflight: Set<URL> = []
    @ObservationIgnored private var tokenCache: GhAuthTokenCache?

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let decode: (Data) -> NSImage?
    let limit: Int
    let freshFor: TimeInterval
    static let firstRetry: TimeInterval = 30
    static let maxRetry: TimeInterval = 15 * 60

    init(fetch: @escaping Fetch, now: @escaping () -> Date = Date.init,
         decode: @escaping (Data) -> NSImage? = { NSImage(data: $0) }, limit: Int = 500, freshFor: TimeInterval = 24 * 3600) {
        self.fetch = fetch
        self.now = now
        self.decode = decode
        self.limit = limit
        self.freshFor = freshFor
    }

    /// Call once signed in, so avatar requests from here on carry the same credentials as every other
    /// `gh`-backed request.
    func configureAuth(gh: any GhRunner) { tokenCache = GhAuthTokenCache(gh: gh) }

    var cachedCount: Int { images.count }

    func image(for url: URL?) -> NSImage? {
        guard let url, let entry = images[url] else { return nil }
        useCounter += 1
        lastUsed[url] = useCounter
        return entry.image
    }

    func load(_ url: URL?) async {
        guard let url, inflight.insert(url).inserted else { return }
        defer { inflight.remove(url) }
        if let f = failures[url], now() < f.retryAt { return }
        if let entry = images[url], now().timeIntervalSince(entry.fetchedAt) < freshFor { return }
        let token = await tokenCache?.token()

        if images[url] == nil, let (data, _) = try? await fetch(url, .returnCacheDataDontLoad, token), let image = decode(data) {
            store(image, for: url, fetchedAt: .distantPast) // shown now, but not trusted as current
        }
        do {
            let (data, status) = try await fetch(url, .reloadRevalidatingCacheData, token)
            guard status == 200, let image = decode(data) else {
                if status == 401 { await tokenCache?.invalidate() } // the cached token stopped working; refetch next time
                recordFailure(url)
                return
            }
            store(image, for: url, fetchedAt: now())
            failures[url] = nil
        } catch {
            if !Task.isCancelled { recordFailure(url) } // a row scrolling away cancels its load; that is not a failure
        }
    }

    private func store(_ image: NSImage, for url: URL, fetchedAt: Date) {
        images[url] = Entry(image: image, fetchedAt: fetchedAt)
        useCounter += 1
        lastUsed[url] = useCounter
        while images.count > limit, let oldest = lastUsed.filter({ images[$0.key] != nil && $0.key != url }).min(by: { $0.value < $1.value }) {
            images[oldest.key] = nil
            lastUsed[oldest.key] = nil
        }
    }

    private func recordFailure(_ url: URL) {
        let attempts = (failures[url]?.attempts ?? 0) + 1
        let delay = min(Self.maxRetry, Self.firstRetry * pow(2, Double(attempts - 1)))
        failures[url] = (now().addingTimeInterval(delay), attempts)
    }

    private nonisolated static let session: URLSession = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ghview-mac/avatars", isDirectory: true)
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 10 << 20, diskCapacity: 50 << 20, directory: dir)
        return URLSession(configuration: config)
    }()

    private nonisolated static func liveFetch(_ url: URL, _ policy: URLRequest.CachePolicy, _ token: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: url, cachePolicy: policy)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
