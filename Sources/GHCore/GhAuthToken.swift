import Foundation

/// Caches the token `gh` is authenticated with, so it can be attached to requests GHView makes directly (not
/// through `gh api`/`gh graphql`) - namely avatar images. An organization or account behind SAML SSO serves an
/// SSO sign-in page instead of the image to an unauthenticated request; carrying the same token every other
/// `gh`-backed call already uses fixes that.
public actor GhAuthTokenCache {
    private var cached: String?
    private let gh: any GhRunner

    public init(gh: any GhRunner) { self.gh = gh }

    /// The cached token, fetching it with `gh auth token` the first time. `nil` if that fails (no `gh`, not
    /// signed in, ...) - callers should just fall back to an unauthenticated request in that case.
    public func token() async -> String? {
        if let cached { return cached }
        guard let data = try? await gh.run(["auth", "token"]) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        cached = token
        return token
    }

    /// Drops the cached token, so the next call to `token()` fetches a fresh one. Used when a request made with
    /// the cached token still comes back unauthorized.
    public func invalidate() { cached = nil }
}
