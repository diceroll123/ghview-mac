import Foundation

public struct RepoId: Hashable, Sendable, Codable {
    public var owner: String
    public var name: String
    public init(owner: String, name: String) { self.owner = owner; self.name = name }
    public var fullName: String { "\(owner)/\(name)" }
    /// The repository's page on GitHub, and its open pull requests.
    public var url: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
    public var pullRequestsURL: URL { URL(string: "https://github.com/\(owner)/\(name)/pulls")! }
}

public struct PrId: Hashable, Sendable, Codable {
    public var repo: RepoId
    public var number: Int
    public init(repo: RepoId, number: Int) { self.repo = repo; self.number = number }
}

public struct PRLabel: Hashable, Sendable, Codable {
    public var name: String
    public var color: String
    public init(name: String, color: String) { self.name = name; self.color = color }
}

public enum ReviewStatus: String, Sendable, Codable {
    case approved, changesRequested, pending, unknown

    init(decision: String?) {
        switch decision {
        case "APPROVED": self = .approved
        case "CHANGES_REQUESTED": self = .changesRequested
        case "REVIEW_REQUIRED": self = .pending
        default: self = .unknown
        }
    }
}

/// GitHub's repository visibility: public, fully private, or "internal" (visible to everyone in an Enterprise
/// account, but not outside it). Internal repos set `isPrivate` too, so the enum is needed to tell them apart.
public enum RepoVisibility: String, Sendable, Codable {
    case `public`, `private`, `internal`

    init(graphQL value: String?) {
        switch value {
        case "PRIVATE": self = .private
        case "INTERNAL": self = .internal
        default: self = .public
        }
    }
}

public enum MergeableState: String, Sendable, Codable {
    case clean, behind, dirty, blocked, unstable, hasHooks, draft, unknown

    /// From GitHub's coarse `mergeable` field (MERGEABLE/CONFLICTING/UNKNOWN). The full breakdown
    /// (`mergeStateStatus`, with BEHIND/BLOCKED/UNSTABLE/HAS_HOOKS/DRAFT) requires GitHub to actually compute
    /// mergeability, which is too expensive to ask for on every PR in a list; this only ever distinguishes an
    /// actual conflict from "nothing to flag yet".
    init(graphQL value: String?) {
        switch value {
        case "CONFLICTING": self = .dirty
        case "MERGEABLE": self = .clean
        default: self = .unknown
        }
    }
}

public enum CheckStatus: String, Sendable, Codable {
    case passing, failing, cancelled, pending, skipped, unknown

    /// Worst-wins aggregation, matching the Rust app: failing > cancelled > pending > passing.
    /// Skipped checks never change the outcome: passes plus skips is passing, and skips alone count as passing too.
    public static func aggregate(_ statuses: [CheckStatus]) -> CheckStatus {
        if statuses.isEmpty { return .unknown }
        if statuses.contains(.failing) { return .failing }
        if statuses.contains(.cancelled) { return .cancelled }
        if statuses.contains(.pending) { return .pending }
        if statuses.allSatisfy({ $0 == .passing || $0 == .skipped }) { return .passing }
        return .unknown
    }
}

public struct CheckRun: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var databaseId: Int?
    public var name: String
    public var url: String?
    public var status: CheckStatus
    public init(id: String, databaseId: Int? = nil, name: String, url: String? = nil, status: CheckStatus) {
        self.id = id; self.databaseId = databaseId; self.name = name; self.url = url; self.status = status
    }
}

public struct PR: Hashable, Sendable, Codable, Identifiable {
    public var id: PrId
    public var title: String
    public var author: String
    public var isDraft: Bool
    public var isOpen: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var url: String
    public var headRef: String
    public var baseRef: String
    public var headSha: String
    public var additions: Int
    public var deletions: Int
    public var comments: Int
    public var autoMerge: Bool
    public var reviewStatus: ReviewStatus
    public var viewerApproved: Bool
    public var mergeable: MergeableState
    /// Logins of users whose review is requested directly. Teams are in `requestedTeams`, so a team slug can
    /// never be mistaken for a user with the same name.
    public var requestedReviewers: [String]
    public var labels: [PRLabel]
    public var checks: [CheckRun]
    public var checkSummary: CheckStatus
    /// Per-state totals for the checks bar; exact even when a PR has more checks than we fetch.
    public var checkCounts: CheckCounts = CheckCounts()
    public var requestedTeams: [ReviewTeam] = []
    /// How many labels and review requests GitHub reports in total; the list query only carries the first 20.
    public var labelTotal: Int?
    public var reviewRequestTotal: Int?

    public init(id: PrId, title: String, author: String, isDraft: Bool, isOpen: Bool, createdAt: Date, updatedAt: Date,
                url: String, headRef: String, baseRef: String, headSha: String, additions: Int, deletions: Int,
                comments: Int, autoMerge: Bool, reviewStatus: ReviewStatus, viewerApproved: Bool, mergeable: MergeableState,
                requestedReviewers: [String] = [], labels: [PRLabel] = [], checks: [CheckRun] = [],
                checkSummary: CheckStatus, checkCounts: CheckCounts = CheckCounts(), requestedTeams: [ReviewTeam] = [],
                labelTotal: Int? = nil, reviewRequestTotal: Int? = nil) {
        self.id = id; self.title = title; self.author = author; self.isDraft = isDraft; self.isOpen = isOpen
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.url = url
        self.headRef = headRef; self.baseRef = baseRef; self.headSha = headSha
        self.additions = additions; self.deletions = deletions; self.comments = comments
        self.autoMerge = autoMerge; self.reviewStatus = reviewStatus; self.viewerApproved = viewerApproved
        self.mergeable = mergeable; self.requestedReviewers = requestedReviewers; self.labels = labels
        self.checks = checks; self.checkSummary = checkSummary; self.checkCounts = checkCounts
        self.requestedTeams = requestedTeams; self.labelTotal = labelTotal; self.reviewRequestTotal = reviewRequestTotal
    }

    public var labelsTruncated: Bool { (labelTotal ?? labels.count) > labels.count }
    public var reviewersTruncated: Bool {
        let loaded = requestedReviewers.count + requestedTeams.count
        return (reviewRequestTotal ?? loaded) > loaded
    }

    public var number: Int { id.number }
    public var repo: RepoId { id.repo }
    /// The first seven characters of the head commit, as git and GitHub abbreviate it.
    public var shortHeadSha: String { String(headSha.prefix(7)) }
    /// The head commit's page on GitHub.
    public var headCommitURL: URL? { URL(string: "https://github.com/\(repo.fullName)/commit/\(headSha)") }
    public var isDependabot: Bool { author == "dependabot[bot]" || author == "dependabot" }
    public var isBot: Bool { Accounts.isBot(author) }
}

public struct ReviewTeam: Hashable, Sendable, Codable {
    public var org: String
    public var slug: String
    public init(org: String, slug: String) { self.org = org; self.slug = slug }
    /// `org/slug`, how GitHub writes a team in review requests.
    public var fullName: String { "\(org)/\(slug)" }
}

public struct RepoInfo: Hashable, Sendable, Codable, Identifiable {
    public var id: RepoId
    public var language: String?
    public var pushedAt: Date?
    public var stars: Int
    public var openPRs: Int
    public var isArchived: Bool
    public var isPrivate: Bool
    /// Public, fully private, or GitHub Enterprise "internal" (`isPrivate` is also true for internal repos).
    public var visibility: RepoVisibility = .public
    public var canPush: Bool
    public var allowAutoMerge: Bool
    public var hasIssues: Bool
    /// A fork of another repository.
    public var isFork: Bool = false
    /// Strategies the repository's settings permit. GitHub rejects a merge made any other way.
    public var allowedMergeMethods: [MergeMethod] = MergeMethod.allCases
    /// The latest release's tag and publish date, if the repository has ever published one.
    public var releaseTag: String? = nil
    public var releaseDate: Date? = nil

    public init(id: RepoId, language: String? = nil, pushedAt: Date? = nil, stars: Int = 0, openPRs: Int = 0,
                isArchived: Bool = false, isPrivate: Bool = false, visibility: RepoVisibility = .public,
                canPush: Bool = true, allowAutoMerge: Bool = true, hasIssues: Bool = true, isFork: Bool = false,
                allowedMergeMethods: [MergeMethod] = MergeMethod.allCases, releaseTag: String? = nil, releaseDate: Date? = nil) {
        self.id = id; self.language = language; self.pushedAt = pushedAt; self.stars = stars; self.openPRs = openPRs
        self.isArchived = isArchived; self.isPrivate = isPrivate; self.visibility = visibility
        self.canPush = canPush; self.allowAutoMerge = allowAutoMerge; self.hasIssues = hasIssues; self.isFork = isFork
        self.allowedMergeMethods = allowedMergeMethods; self.releaseTag = releaseTag; self.releaseDate = releaseDate
    }
}
