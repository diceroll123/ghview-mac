import Foundation

// MARK: Inbox sections

/// The six groups of GitHub's pull request inbox. Which one a PR belongs to is decided in exactly one place,
/// `classify`, so the rules are easy to adjust.
public enum InboxSection: String, CaseIterable, Codable, Sendable, Identifiable {
    case needsYourReview, needsTeamsReview, yourDrafts, waiting, needsAction, readyToMerge

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .needsYourReview: "Needs your review"
        case .needsTeamsReview: "Needs your teams' review"
        case .yourDrafts: "Your drafts"
        case .waiting: "Waiting for review or checks"
        case .needsAction: "Needs action"
        case .readyToMerge: "Ready to merge"
        }
    }

    public var symbol: String {
        switch self {
        case .needsYourReview: "eye"
        case .needsTeamsReview: "person.2"
        case .yourDrafts: "pencil.and.outline"
        case .waiting: "clock"
        case .needsAction: "exclamationmark.circle"
        case .readyToMerge: "checkmark.circle"
        }
    }

    /// The GitHub search that comes closest to this section, shown (read-only) in the filter box. The section
    /// itself is decided by `classify`, which GitHub's search syntax cannot fully express.
    public var queryText: String {
        switch self {
        case .needsYourReview: "user-review-requested:@me draft:false"
        case .needsTeamsReview: "review-requested:@me -user-review-requested:@me draft:false"
        case .yourDrafts: "author:@me draft:true"
        case .waiting: "author:@me draft:false -review:changes_requested -status:failure"
        case .needsAction: "author:@me draft:false (review:changes_requested OR status:failure)"
        case .readyToMerge: "author:@me draft:false review:approved status:success"
        }
    }

    /// Why `queryText` is only an approximation, for sections where it is.
    public var queryNote: String? {
        switch self {
        case .needsAction: "Also includes PRs with merge conflicts or cancelled checks, which GitHub's search cannot express."
        case .waiting: "Excludes PRs ready to merge; GitHub's search cannot express that or merge state."
        case .readyToMerge: "Also requires a clean merge state, which GitHub's search cannot express."
        default: nil
        }
    }

    /// The inbox is built from PRs the viewer wrote and PRs they were asked to review.
    public static let searchScopes = ["author:@me", "review-requested:@me"]

    /// The section `pr` belongs to for `viewer`, or nil if it belongs to none.
    ///
    /// - The viewer's own PR: a draft is `yourDrafts`. Otherwise it needs action if a reviewer asked for changes,
    ///   checks failed or were cancelled, or the branch conflicts. Otherwise it is ready if it is approved, its
    ///   checks pass (or it has none) and GitHub reports a clean merge state. Anything else is `waiting`.
    /// - Someone else's non-draft PR (it came from `review-requested:@me`): `needsYourReview` if the viewer was
    ///   asked by name, otherwise `needsTeamsReview` (the search also matches teams the viewer is on).
    public static func classify(_ pr: PR, viewer: String) -> InboxSection? {
        let me = viewer.lowercased()
        if pr.author.lowercased() == me {
            if pr.isDraft { return .yourDrafts }
            if pr.reviewStatus == .changesRequested || pr.checkSummary == .failing || pr.checkSummary == .cancelled
                || pr.mergeable == .dirty
            {
                return .needsAction
            }
            let checksOK = pr.checkSummary == .passing || (pr.checkSummary == .unknown && pr.checkCounts.isEmpty)
            if pr.reviewStatus == .approved, checksOK, pr.mergeable == .clean || pr.mergeable == .hasHooks { return .readyToMerge }
            return .waiting
        }
        guard !pr.isDraft else { return nil }
        if pr.requestedReviewers.contains(where: { $0.lowercased() == me }) { return .needsYourReview }
        return pr.requestedTeams.isEmpty ? nil : .needsTeamsReview
    }

    /// PRs per section; sections with none are absent.
    public static func counts(of prs: [PR], viewer: String) -> [InboxSection: Int] {
        var out: [InboxSection: Int] = [:]
        for pr in prs { if let s = classify(pr, viewer: viewer) { out[s, default: 0] += 1 } }
        return out
    }
}

// MARK: Quick searches

/// The fixed searches under the inbox, matching github.com/pulls.
public enum QuickSearch: String, CaseIterable, Codable, Sendable, Identifiable {
    case authored, assigned, involves, reviewRequests

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .authored: "Authored by me"
        case .assigned: "Assigned to me"
        case .involves: "Involves me"
        case .reviewRequests: "Review requests"
        }
    }

    public var symbol: String {
        switch self {
        case .authored: "person"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .involves: "bubble.left.and.bubble.right"
        case .reviewRequests: "eye"
        }
    }

    /// The search qualifier; the full query is `is:pr is:open <scope>`.
    public var scope: String {
        switch self {
        case .authored: "author:@me"
        case .assigned: "assignee:@me"
        case .involves: "involves:@me"
        case .reviewRequests: "review-requested:@me"
        }
    }
}

// MARK: Saved views

/// A search the user keeps in the sidebar. GitHub exposes no API for its own saved views, so these are local.
public struct SavedView: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// GitHub search syntax, e.g. `label:bug org:acme`. `is:pr is:open` is added when it runs.
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }

    /// The scope handed to the PR search: the user's own qualifiers, with `is:pr is:open` supplied by the app.
    public var scope: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum SavedViewError: Error, LocalizedError, Equatable {
    case emptyName, emptyQuery, duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Give the view a name."
        case .emptyQuery: "Enter a search, for example: label:bug org:acme"
        case .duplicateName(let n): "A view named \(n) already exists."
        }
    }
}

public extension SavedView {
    /// Trims the name and query and checks them against the other views (`editing` is the one being changed, so
    /// keeping its own name is fine). Names compare case-insensitively.
    static func validate(name: String, query: String, among views: [SavedView], editing id: UUID? = nil) throws
        -> (name: String, query: String)
    {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw SavedViewError.emptyName }
        guard !q.isEmpty else { throw SavedViewError.emptyQuery }
        if views.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            throw SavedViewError.duplicateName(n)
        }
        return (n, q)
    }
}

// MARK: Destinations

/// Where the sidebar selection points. Every destination opens the same flat PR list.
public enum SidebarDestination: Hashable, Sendable {
    case inbox(InboxSection)
    case search(QuickSearch)
    case savedView(UUID)
    case sources(Set<String>)
    case repo(RepoId)

    /// Sidebar tag used by `List(selection:)`.
    public var tag: String {
        switch self {
        case .inbox(let s): "inbox:\(s.rawValue)"
        case .search(let q): "search:\(q.rawValue)"
        case .savedView(let id): "view:\(id.uuidString)"
        case .sources(let ids): ids.sorted().joined(separator: ",")
        case .repo(let r): "repo:\(r.fullName)"
        }
    }

    /// Parses a sidebar tag. Source ids are plain names (no colon); several of them are joined with commas.
    public static func from(tag: String) -> SidebarDestination? {
        guard let colon = tag.firstIndex(of: ":") else {
            let ids = Set(tag.split(separator: ",").map(String.init))
            return ids.isEmpty ? nil : .sources(ids)
        }
        let kind = tag[..<colon], value = String(tag[tag.index(after: colon)...])
        switch kind {
        case "inbox": return InboxSection(rawValue: value).map(SidebarDestination.inbox)
        case "search": return QuickSearch(rawValue: value).map(SidebarDestination.search)
        case "view": return UUID(uuidString: value).map(SidebarDestination.savedView)
        case "repo":
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? .repo(RepoId(owner: parts[0], name: parts[1])) : nil
        default: return nil
        }
    }

    /// True for destinations answered by the shared inbox load rather than by their own query.
    public var isInbox: Bool { if case .inbox = self { true } else { false } }
}

// MARK: Layout

/// What the sidebar's top blocks look like: what is hidden, what is expanded, and the saved views. Stored per
/// account so signing in as someone else never shows the previous user's views.
public struct SidebarLayout: Codable, Sendable, Equatable {
    public var inboxHidden = false
    public var quickSearchesHidden = false
    public var savedViewsHidden = false
    /// Individual entries hidden, by tag (`inbox:needsAction`, `search:involves`, `view:<uuid>`).
    public var hiddenEntries: Set<String> = []
    public var inboxExpanded = true
    public var savedViewsExpanded = true
    /// Sources whose repositories are shown, by source id.
    public var expandedSources: Set<String> = []
    public var savedViews: [SavedView] = []

    public init() {}

    public static func defaultsKey(for scope: AccountScope) -> String { "sidebarLayout.v1.\(scope.id)" }

    public static func load(from defaults: UserDefaults = .standard, scope: AccountScope) -> SidebarLayout {
        guard let data = defaults.data(forKey: defaultsKey(for: scope)),
            let layout = try? JSONDecoder().decode(SidebarLayout.self, from: data)
        else { return SidebarLayout() }
        return layout
    }

    public func save(to defaults: UserDefaults = .standard, scope: AccountScope) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey(for: scope)) }
    }

    public func isHidden(_ section: InboxSection) -> Bool { inboxHidden || hiddenEntries.contains("inbox:\(section.rawValue)") }
    /// The built-in searches live inside the Views group, so hiding the group hides them too.
    public func isHidden(_ search: QuickSearch) -> Bool {
        savedViewsHidden || quickSearchesHidden || hiddenEntries.contains("search:\(search.rawValue)")
    }
    public func isHidden(_ view: SavedView) -> Bool { savedViewsHidden || hiddenEntries.contains("view:\(view.id.uuidString)") }

    public var visibleSections: [InboxSection] { InboxSection.allCases.filter { !isHidden($0) } }
    public var visibleSearches: [QuickSearch] { QuickSearch.allCases.filter { !isHidden($0) } }
    public var visibleViews: [SavedView] { savedViews.filter { !isHidden($0) } }

    /// Entries hidden one by one (not counting a hidden block), for the "show hidden entries" command.
    public var hiddenEntryCount: Int { hiddenEntries.count }

    /// Whether `destination` is on screen under this layout; a hidden one cannot stay selected.
    public func shows(_ destination: SidebarDestination) -> Bool {
        switch destination {
        case .inbox(let s): !isHidden(s)
        case .search(let q): !isHidden(q)
        case .savedView(let id): savedViews.first { $0.id == id }.map { !isHidden($0) } ?? false
        case .sources, .repo: true
        }
    }

    /// Whether anything needs the inbox PR set: a visible inbox section, so a hidden inbox saves its queries.
    public var needsInboxData: Bool { !visibleSections.isEmpty }
}

// MARK: Counts for searches

/// Open-PR counts for arbitrary search scopes, one GraphQL point for the lot.
public enum SearchCounts {
    /// `$q0: String!, ...` variables keep user-written queries (quotes and all) out of the query text.
    static func build(count: Int) -> String {
        let decls = (0..<count).map { "$q\($0): String!" }.joined(separator: ", ")
        var parts = ["rateLimit { remaining limit cost resetAt used nodeCount }"]
        for i in 0..<count { parts.append("o\(i): search(query: $q\(i), type: ISSUE, first: 1) { issueCount }") }
        return "query(\(decls)) {\n  " + parts.joined(separator: "\n  ") + "\n}"
    }

    public struct Result: Sendable, Equatable {
        public var counts: [String: Int]
        /// Scopes GitHub refused (e.g. a malformed saved query), with the reason.
        public var errors: [String: String]
    }

    /// Counts the open PRs matching each scope (`is:pr is:open <scope>`). Keys of the result are the scopes.
    public static func fetch(_ scopes: [String], client: GraphQLClient) async throws -> (result: Result, rateLimits: [RateLimit]) {
        guard !scopes.isEmpty else { return (Result(counts: [:], errors: [:]), []) }
        var vars: [String: Any?] = [:]
        for (i, s) in scopes.enumerated() { vars["q\(i)"] = "is:pr is:open \(s)" }
        let (response, errors): (SourceCountsQuery.Response, [GraphQLErrorInfo]) =
            try await client.queryAllowingErrors(build(count: scopes.count), variables: vars)
        var counts: [String: Int] = [:], failed: [String: String] = [:]
        for (i, s) in scopes.enumerated() {
            if let e = errors.first(where: { $0.path.first == "o\(i)" }) {
                failed[s] = e.message
            } else if let n = response.counts["o\(i)"] ?? nil {
                counts[s] = n
            }
        }
        return (Result(counts: counts, errors: failed), response.rateLimit.map { [$0] } ?? [])
    }
}
