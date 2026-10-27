import Foundation

public enum Accounts {
    /// GitHub App accounts end in "[bot]"; a few well-known automation accounts show up without it.
    public static func isBot(_ login: String) -> Bool {
        let a = login.lowercased()
        return a.hasSuffix("[bot]") || ["dependabot", "renovate", "github-actions", "copilot"].contains(a)
    }
}


/// Who the app is acting as. Everything stored per user (sources, cached counts) is keyed by it, so signing in to
/// another account never shows or edits the first account's data.
public struct AccountScope: Hashable, Sendable {
    /// GHView builds github.com URLs and identities throughout; other hosts are not supported.
    public static let supportedHost = "github.com"

    public var host: String
    public var login: String
    public init(host: String = AccountScope.supportedHost, login: String) { self.host = host; self.login = login }

    public var id: String { "\(host)/\(login.lowercased())" }
    public var catalogKey: String { "\(SourceCatalog.defaultsKey).\(id)" }
    public var countsFileName: String { "source-counts.\(host).\(login.lowercased()).json" }
}

/// Why the app could not reach GitHub, in terms the user can act on.
public enum ConnectionProblem: Equatable, Sendable {
    case missingCLI, notSignedIn, offline, other(String)
    /// `gh` is now signed in as someone other than the account this session started with.
    case accountChanged(was: String, now: String)
    case unsupportedHost(String)

    public static func classify(_ error: Error) -> ConnectionProblem {
        if let err = error as? GhError {
            let text = err.stderr.lowercased()
            if err.status == 127 { return .missingCLI }
            if text.contains("gh auth login") || text.contains("not logged in") || text.contains("bad credentials")
                || text.contains("http 401") || text.contains("authentication") || text.contains("gh_token") {
                return .notSignedIn
            }
            if err.status == 124 || ["no such host", "network is unreachable", "dial tcp", "i/o timeout", "could not resolve",
                                     "connection refused", "timed out", "offline"].contains(where: text.contains) {
                return .offline
            }
        }
        return .other(error.localizedDescription)
    }

    public var title: String {
        switch self {
        case .missingCLI: "GitHub CLI not found"
        case .notSignedIn: "Not signed in to GitHub"
        case .offline: "Cannot reach GitHub"
        case .other: "Could not connect to GitHub"
        case .accountChanged: "The GitHub account changed"
        case .unsupportedHost: "Only github.com is supported"
        }
    }

    public var advice: String {
        switch self {
        case .missingCLI: "GHView uses the GitHub CLI. Install it with `brew install gh` (or from cli.github.com), then retry."
        case .notSignedIn: "Run `gh auth login` in Terminal, then retry."
        case .offline: "Check your network connection, then retry."
        case .other(let message): message
        case .accountChanged(let was, let now):
            "GHView was showing @\(was), but `gh` is now signed in as @\(now). Nothing was changed. Retry to switch to @\(now)."
        case .unsupportedHost(let host):
            "GHView works with github.com only, but GH_HOST is set to \(host). Unset it and relaunch."
        }
    }
}
