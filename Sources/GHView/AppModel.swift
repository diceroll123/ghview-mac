import SwiftUI
import GHCore

enum PRSort: String, CaseIterable, Identifiable {
    case newest = "Newest", recentlyUpdated = "Recently updated", oldest = "Oldest", needsReview = "Needs review"
    var id: String { rawValue }
}

enum DiffState {
    case loading
    case loaded([DiffFile])
    case failed(String)
}

enum ActivityState {
    case loading
    case loaded(PRActivity)
    case failed(String)
}

/// Progress of a running batch action (merge, close, a dependabot command, ...), shown at the bottom of the
/// PR list. `total` of 1 just means "working", with no count to show.
struct BatchProgress: Equatable {
    var done: Int
    var total: Int
}

enum ChecksState {
    case loading
    case loaded(checks: [CheckRun], counts: CheckCounts)
    case failed(String)
}

enum ReviewersState {
    case loading
    case loaded(reviewers: [String], teams: [ReviewTeam])
    case failed(String)
}

/// An action the user must confirm because it touches several PRs and cannot be undone.
struct PendingAction: Identifiable {
    let id = UUID()
    var action: PrAction
    var targets: [PR]
    var methods: [PrId: MergeMethod] = [:]

    var title: String {
        let n = targets.count
        switch action {
        case .merge: return "Merge \(n) pull requests?"
        case .autoMerge: return "Enable auto-merge on \(n) pull requests?"
        case .close: return "Close \(n) pull requests?"
        default: return "Run on \(n) pull requests?"
        }
    }

    var message: String {
        let merging = action == .merge || action == .autoMerge
        var lines = targets.prefix(12).map { pr in
            let how = merging ? "  [\(methods[pr.id]?.rawValue ?? "no method allowed")]" : ""
            return "\(pr.repo.fullName)#\(pr.number)  \(pr.title)\(how)"
        }
        if targets.count > 12 { lines.append("and \(targets.count - 12) more") }
        return lines.joined(separator: "\n")
    }
}

struct CommentDraft: Equatable {
    var text = ""
    var posting = false
    var error: String?
}

@MainActor
@Observable
final class AppModel {
    private(set) var gh: (any GhRunner)?
    private var client: GraphQLClient?
    private var actions: PrActions?

    var viewer: Viewer?
    var catalog = SourceCatalog()
    /// What the sidebar shows. Hidden sources stay in the catalog and in `allSources`.
    var sources: [Source] { catalog.visibleSources }
    var allSources: [Source] { catalog.allSources }
    var hiddenCount: Int { catalog.hiddenCount }

    /// Open and review-requested PR counts per source id; seeded from disk so badges show before the network answers.
    var counts: [String: SourceCounts] = [:]
    @ObservationIgnored let defaults: UserDefaults
    let settings: AppSettings
    /// The cache file for the current account; until the account is known it is the one shared file from before
    /// accounts were separated.
    @ObservationIgnored private(set) var countsURL: URL
    private(set) var account: AccountScope?
    private let legacyCountsURL: URL

    init(defaults: UserDefaults = .standard, countsURL: URL = SourceCountsCache.defaultURL) {
        self.defaults = defaults
        self.settings = AppSettings(defaults: defaults)
        self.countsURL = countsURL
        self.legacyCountsURL = countsURL
        ghCalls.onChange { [weak self] calls in Task { @MainActor in self?.callLog = calls } }
        // Show the last account's numbers at once, before the network confirms who is signed in.
        if let last = defaults.string(forKey: Self.lastAccountKey).flatMap(Self.scope(fromID:)) {
            self.countsURL = SourceCountsCache.url(for: last, beside: countsURL)
        }
        counts = SourceCountsCache.load(from: self.countsURL)
        mergeMethod = MergeMethod(rawValue: defaults.string(forKey: "mergeMethod") ?? "") ?? .squash
    }
    private var countedIDs: Set<String> = []
    private var countsLoading = false
    @ObservationIgnored private var countsTimer: Task<Void, Never>?
    /// Where the sidebar points: an inbox section, a quick search, a saved view, one or several sources, or one
    /// repository. Every destination opens the same flat PR list.
    var destination: SidebarDestination? {
        didSet {
            guard destination != oldValue else { return }
            // A search destination starts from its own query, which the filter box then shows and edits.
            searchText = defaultSearchText ?? ""
            searchError = nil
            // The repository pane belongs to a source's Repos view: it follows the selected sources, and stays while
            // a repository from it is open. Anything else closes it.
            switch destination {
            case .sources(let ids): paneSourceIDs = ids
            case .repo: if !openingRepoFromPane { browsingRepos = false }
            default: browsingRepos = false
            }
        }
    }

    // MARK: Repos | PRs for sources

    /// The Repos view of the selected sources is open: a repository list with the chosen repository's PRs beside it.
    var browsingRepos = false
    /// The sources whose repositories the pane lists: the selected ones, remembered while a repository is open.
    private(set) var paneSourceIDs: Set<String> = []
    @ObservationIgnored private var openingRepoFromPane = false

    var paneSources: [Source] { catalog.allSources.filter { paneSourceIDs.contains($0.id) && !catalog.isHidden($0) } }

    /// The repository pane is on screen: for users or organizations in Repos view, and for a repository opened from it.
    var showsRepoPane: Bool {
        guard browsingRepos else { return false }
        switch destination {
        case .sources: return activeSources.contains { $0.repoId == nil }
        case .repo: return true
        default: return false
        }
    }

    var isBrowsingRepos: Bool { showsRepoPane }

    /// The Repos | PRs segment applies to users and organizations, which have repositories to list, and stays while
    /// a repository opened from that list is shown. It is not shown for a repository source on its own.
    var showsSourceSegment: Bool {
        switch destination {
        case .sources: activeSources.contains { $0.repoId == nil }
        case .repo: browsingRepos
        default: false
        }
    }

    /// Repositories of the pane's sources, newest push first when several are combined.
    var browsedRepos: [RepoInfo] {
        let sources = paneSources
        let all = sources.flatMap { source -> [RepoInfo] in
            if let repo = source.repoId { return repoInfo(for: repo).map { [$0] } ?? [] }
            return repos(in: source)
        }
        return sources.count > 1 ? all.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) } : all
    }

    /// Switches the segment. Repos opens the repository pane for the selected sources; PRs closes it, and from an
    /// open repository goes back to all of the sources' PRs.
    func setBrowsingRepos(_ on: Bool) {
        switch destination {
        case .sources:
            guard showsSourceSegment else { return }
            browsingRepos = on
            loadPRs()
        case .repo where !on && browsingRepos:
            destination = .sources(paneSourceIDs)
            browsingRepos = false
            loadPRs()
        default: break
        }
    }

    /// Opens a repository from the pane, which stays open beside its PRs.
    func openRepo(_ repo: RepoId) {
        openingRepoFromPane = true
        destination = .repo(repo)
        openingRepoFromPane = false
    }

    /// For the shortcuts and saved views the filter box holds the GitHub search that produces the list, and
    /// editing it runs a new search. For sources, repos and the inbox it is the local filter instead.
    var searchText = ""
    var searchError: String?
    @ObservationIgnored var lastLoadedQuery: String?

    var isSearchDestination: Bool {
        switch destination { case .search, .savedView: true; default: false }
    }

    /// The query a search destination starts with, which "reset" returns to.
    var defaultSearchText: String? {
        switch destination {
        case .search(let q): q.scope
        case .savedView(let id): layout.savedViews.first { $0.id == id }?.query
        default: nil
        }
    }
    /// Sources selected together (Cmd or Shift-click); empty when the destination is something else.
    var selectedSourceIDs: Set<String> {
        get { if case .sources(let ids) = destination { ids } else { [] } }
        set {
            guard newValue != selectedSourceIDs else { return } // not a change, so it must not clear another destination
            destination = newValue.isEmpty ? nil : .sources(newValue)
        }
    }
    var activeSources: [Source] { catalog.allSources.filter { selectedSourceIDs.contains($0.id) && !catalog.isHidden($0) } }
    var isCombined: Bool { activeSources.count > 1 }
    /// The single selected source, or nil when none or several are selected. Setting it selects just that one.
    var selectedSource: Source? {
        get { let a = activeSources; return a.count == 1 ? a[0] : nil }
        set { selectedSourceIDs = newValue.map { [$0.id] } ?? [] }
    }
    /// The repository shown, when the destination is one.
    var selectedRepo: RepoId? {
        get { if case .repo(let r) = destination { r } else { nil } }
        set {
            if let r = newValue { destination = .repo(r) }
            else if selectedRepo != nil { destination = nil }
        }
    }
    var sourceTitle: String {
        switch destination {
        case .inbox(let s): return s.title
        case .search(let q): return q.title
        case .savedView(let id): return layout.savedViews.first { $0.id == id }?.name ?? "Saved view"
        case .repo(let r): return r.fullName
        case .sources, nil:
            let a = activeSources
            return a.count == 1 ? a[0].displayName : (a.count > 1 ? "\(a.count) sources" : "GHView")
        }
    }
    /// The sidebar's top blocks and the sources whose repositories are shown. Saved per account.
    var layout = SidebarLayout() {
        didSet { if let account { layout.save(to: defaults, scope: account) } }
    }
    @ObservationIgnored private var repoCache: [String: (date: Date, repos: [RepoInfo], truncated: Bool)] = [:]
    @ObservationIgnored private var prPager: CombinedPager?
    /// Every repository loaded so far, across the sources whose repositories have been fetched.
    var repos: [RepoInfo] = []
    /// Permissions for repositories that have PRs on screen but are not in `repos` (a source whose repos
    /// are not expanded, an inbox or search result, or past the enumeration cap), fetched on their own. A repo in `failedRepoInfo` could not be loaded, which is not a denial.
    private(set) var extraRepoInfo: [RepoId: RepoInfo] = [:]
    private(set) var failedRepoInfo: Set<RepoId> = []
    @ObservationIgnored private var loadingRepoInfo: Set<RepoId> = []
    nonisolated static let maxReposPerSource = 2000
    var prs: [PR] = []
    var prCursor: String?
    var hasMorePRs = false
    /// Set when GitHub's search limit makes part of the current result set unreachable: how many of how many.
    var searchShortfall: (received: Int, total: Int)?
    /// Sources (search chunks) that failed while others delivered. The list shows what loaded and offers a retry.
    var prFailures: [CombinedPager.Failure] = []
    /// Sources whose repositories could not be listed, by source name.
    var repoFailures: [String: String] = [:]
    var focused: PrId?
    var selection = SelectionState()
    var filter = ""
    var sort: PRSort = .newest
    var rateLimit: RateLimit?
    var requestLog = RequestLog()
    /// Every `gh` call this session with its outcome, newest first (the Request Log window).
    var callLog: [GhCall] = []
    @ObservationIgnored let ghCalls = GhCallLog()
    var rateBuckets: [RateBucket] = []
    /// Set once `loadRateBuckets()` has completed at least once, so the usage popover can tell "still loading"
    /// from "loaded, nothing extra to show" and reserve a skeleton's worth of space either way, rather than
    /// resizing once the (normally near-instant) fetch lands.
    var rateBucketsLoaded = false
    var diffs: [String: DiffState] = [:]
    var activities: [String: ActivityState] = [:]
    var checkRuns: [String: ChecksState] = [:]
    var reviewRequests: [String: ReviewersState] = [:]
    var isStarting = true
    /// Sources whose repository list is being fetched right now.
    var loadingRepoSources: Set<String> = []
    var reposLoading: Bool { !loadingRepoSources.isEmpty }
    var prsLoading = false       // first page, or a refresh
    var prsLoadingMore = false   // subsequent pages
    var hasLoadedPRs = false     // avoids flashing the empty state before data arrives
    var loadFailed = false
    private var loadGeneration = 0
    var error: String?
    /// The user's preferred merge method; a repository that disallows it gets the nearest allowed one.
    var mergeMethod: MergeMethod = .squash {
        didSet { defaults.set(mergeMethod.rawValue, forKey: "mergeMethod") }
    }

    /// "squash" when every target merges that way, otherwise a note that it varies by repository.
    func mergeMethodSummary(for targets: [PR]) -> String {
        let methods = Set(targets.compactMap(method(for:)))
        return methods.count == 1 ? methods.first!.rawValue : "method varies by repository"
    }

    /// What `action` would merge with in each target's repository, for confirmations and tooltips.
    func method(for pr: PR) -> MergeMethod? { ActionOptions(mergeMethod: mergeMethod).method(for: repoInfo(for: pr.repo)) }
    /// PRs with a mutation in flight. A second action on any of them is refused until the first finishes.
    private(set) var busy: Set<PrId> = []
    /// How far a running batch action has gotten, for the progress indicator at the bottom of the list. Nil
    /// when nothing is running.
    private(set) var batchProgress: BatchProgress?
    /// A bulk merge or close waiting for the user to confirm the exact targets.
    var pendingConfirmation: PendingAction?
    /// Set right before opening the Settings window from somewhere that means a specific tab (e.g. "Manage
    /// Sources..."), so it opens there instead of wherever it last was.
    var pendingSettingsTab: SettingsTab?

    private var loadTask: Task<Void, Never>?

    var visiblePRs: [PR] {
        let parsed = PRFilter.parse(effectiveFilter)
        var list = prs.filter { parsed.matches($0, me: viewer?.login) }
        switch sort {
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .oldest: list.sort { $0.createdAt < $1.createdAt }
        case .recentlyUpdated: list.sort { $0.updatedAt > $1.updatedAt }
        case .needsReview:
            func rank(_ s: ReviewStatus) -> Int { switch s { case .pending, .unknown: 0; case .changesRequested: 1; case .approved: 2 } }
            list.sort { (rank($0.reviewStatus), $1.createdAt) < (rank($1.reviewStatus), $0.createdAt) }
        }
        return list
    }

    var isLoading: Bool { reposLoading || prsLoading || prsLoadingMore }

    /// The local filter does not apply to a search destination: there the box is the search itself.
    private var effectiveFilter: String { isSearchDestination || isInboxDestination ? "" : filter }

    var isInboxDestination: Bool { destination?.isInbox == true }

    /// What the filter box shows read-only for an inbox section: the GitHub search that approximates it.
    var inboxQueryText: String? { if case .inbox(let s) = destination { s.queryText } else { nil } }
    var inboxQueryNote: String? { if case .inbox(let s) = destination { s.queryNote } else { nil } }
    var isFiltering: Bool { !PRFilter.parse(effectiveFilter).isEmpty }

    func filterHas(_ token: String) -> Bool { FilterQuery.contains(token, in: filter) }
    func toggleFilter(_ token: String) { filter = FilterQuery.toggling(token, in: filter) }

    var focusedPR: PR? { focused.flatMap { id in prs.first { $0.id == id } } }
    var currentRepo: RepoInfo? { selectedRepo.flatMap(repoInfo(for:)) }

    func repoInfo(for id: RepoId) -> RepoInfo? { repos.first { $0.id == id } ?? extraRepoInfo[id] }

    /// Fetches permissions for PRs' repositories that the repo list does not cover.
    /// With `refresh`, repos already fetched this way are fetched again so their permissions do not go stale.
    func loadMissingRepoInfo(refresh: Bool = false) async {
        guard let client else { return }
        // Repositories added as sources need their flags (private, archived) and permissions too.
        let wanted = Set(prs.map(\.repo)).union(catalog.allSources.compactMap(\.repoId))
        let missing = wanted.filter { id in
            !loadingRepoInfo.contains(id) && (refresh ? !repos.contains { $0.id == id } : repoInfo(for: id) == nil)
        }
        guard !missing.isEmpty else { return }
        loadingRepoInfo.formUnion(missing)
        defer { loadingRepoInfo.subtract(missing) }
        do {
            let result = try await ReposQuery.fetchInfo(missing.sorted { $0.fullName < $1.fullName }, client: client)
            for info in result.repos { extraRepoInfo[info.id] = info }
            failedRepoInfo.subtract(missing)
            failedRepoInfo.formUnion(missing.subtracting(result.repos.map(\.id)))
            for rl in result.rateLimits { record("Repo permissions", rl) }
        } catch {
            failedRepoInfo.formUnion(missing)
        }
    }

    // MARK: Loading

    /// Wires the model to a gh runner. `start()` uses the real CLI; tests pass a scripted one.
    func connect(_ runner: any GhRunner) {
        let runner = LoggingGh(runner, log: ghCalls)
        gh = runner
        client = GraphQLClient(gh: runner)
        actions = PrActions(gh: runner)
        AvatarStore.shared.configureAuth(gh: runner) // so avatars behind SAML SSO load with the same credentials
    }

    // MARK: Account

    static let lastAccountKey = "lastAccount"

    static func scope(fromID id: String) -> AccountScope? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        return AccountScope(host: String(id[..<slash]), login: String(id[id.index(after: slash)...]))
    }

    private var catalogKey: String {
        let scope = account ?? defaults.string(forKey: Self.lastAccountKey).flatMap(Self.scope(fromID:))
        return scope?.catalogKey ?? SourceCatalog.defaultsKey
    }

    /// Makes `scope` the acting account. Switching from another account drops everything that belonged to it
    /// (counts, repos, PRs, drafts, caches) and loads this account's own saved state; a first run after upgrading
    /// adopts the old shared state exactly once.
    private func adopt(_ scope: AccountScope, seeding v: Viewer) {
        let last = defaults.string(forKey: Self.lastAccountKey)
        let switching = (account.map { $0 != scope } ?? false) || (last != nil && last != scope.id)
        if switching {
            counts = [:]; countedIDs = []; destination = nil
            repos = []; repoCache = [:]; repoFailures = [:]; loadingRepoSources = []
            inboxTask?.cancel(); inboxTask = nil
            inboxPRs = []; inboxFailures = []; inboxCapped = false; inboxLoaded = false
            searchCounts = [:]; searchCountErrors = [:]
            extraRepoInfo = [:]; failedRepoInfo = []
            invalidatePRLoad(); clearPRs()
            diffs = [:]; activities = [:]; drafts = [:]
            catalog = SourceCatalog()
        }
        account = scope
        layout = SidebarLayout.load(from: defaults, scope: scope)
        countsURL = SourceCountsCache.url(for: scope, beside: legacyCountsURL)
        if let own = SourceCatalog.load(from: defaults, key: scope.catalogKey) {
            catalog = own
            counts = SourceCountsCache.load(from: countsURL)
        } else if last == nil, let legacy = SourceCatalog.load(from: defaults) {
            // Upgrading: the shared pre-account state belongs to whoever is signed in now, and to nobody else.
            catalog = legacy
            catalog.save(to: defaults, key: scope.catalogKey)
            defaults.removeObject(forKey: SourceCatalog.defaultsKey)
            counts = SourceCountsCache.load(from: legacyCountsURL)
            SourceCountsCache.save(counts, to: countsURL)
            try? FileManager.default.removeItem(at: legacyCountsURL)
        } else {
            catalog = SourceCatalog.seeded(from: SourcesQuery.assemble(viewer: v, config: SourceConfig()))
            catalog.save(to: defaults, key: scope.catalogKey)
            counts = SourceCountsCache.load(from: countsURL)
        }
        defaults.set(scope.id, forKey: Self.lastAccountKey)
    }

    /// True if `gh` is still signed in as the account this session started with (or if that cannot be checked).
    /// A different account stops everything with a clear message rather than silently acting as someone else.
    func accountMatches() async -> Bool {
        guard let gh, let account else { return true }
        guard let data = try? await gh.run(["api", "user", "--jq", ".login"]) else { return true }
        let now = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if now.isEmpty || now.lowercased() == account.login.lowercased() { return true }
        connection = .problem(.accountChanged(was: account.login, now: now))
        return false
    }

    enum Connection: Equatable {
        case connecting, connected
        case problem(ConnectionProblem)
    }

    var connection: Connection = .connecting
    @ObservationIgnored private var starting = false

    /// Connects to GitHub: finds `gh`, reads the viewer, then loads sources and counts. Safe to call again
    /// after a failure (Retry). Ignored while an attempt is running and once connected, so a window that appears
    /// again cannot reset what the user is looking at.
    func start(runner: () throws -> any GhRunner = { try GhCLI() }) async {
        guard !starting, connection != .connected else { return }
        starting = true
        isStarting = true
        connection = .connecting
        defer { starting = false; isStarting = false }

        if let host = ProcessInfo.processInfo.environment["GH_HOST"], !host.isEmpty, host != AccountScope.supportedHost {
            connection = .problem(.unsupportedHost(host))
            return
        }
        // The saved sources are local, so they are shown whatever happens to the network. Until the viewer is
        // known they are the last account's (or an old install's).
        let last = defaults.string(forKey: Self.lastAccountKey).flatMap(Self.scope(fromID:))
        if let saved = SourceCatalog.load(from: defaults, key: last?.catalogKey ?? SourceCatalog.defaultsKey) { catalog = saved }
        do {
            connect(try runner())
            let v = try await SourcesQuery.fetchViewer(client: client!)
            viewer = v
            adopt(AccountScope(login: v.login), seeding: v)
            // Orgs joined since last time arrive flagged "new" (hidden by default); cached counts apply the empty rule at once.
            let discovered = catalog.discover(orgs: v.orgs)
            catalog.updateAutoHidden(counts: counts, keeping: selectedSourceIDs)
            if !discovered.isEmpty { catalog.save(to: defaults, key: catalogKey) }
            connection = .connected
            error = nil
            if destination == nil { selectedSource = sources.first } // the content view's onChange loads its PRs
            else { loadPRs() }
            Task { await loadExpandedRepos() }
            Task { await loadMissingRepoInfo() }
            Task { await loadCounts() }
            Task { await loadSearchCounts() }
            if layout.needsInboxData { Task { await loadInbox() } }
            startCountsTimer()
        } catch {
            connection = .problem(ConnectionProblem.classify(error))
        }
    }

#if DEBUG
    /// Loads fixed, fake data instead of connecting to `gh` at all - for taking screenshots. Debug builds only;
    /// see scripts/generate-screenshot.sh for how this is triggered.
    func startDemo() {
        viewer = Viewer(login: "octocat", orgs: [DemoFixtures.orgLogin])
        account = AccountScope(login: "octocat")
        catalog = SourceCatalog.seeded(from: [.org(DemoFixtures.orgLogin)])
        counts = DemoFixtures.counts
        repoCache[Source.org(DemoFixtures.orgLogin).id] = (date: Date(), repos: DemoFixtures.repos, truncated: false)
        prs = DemoFixtures.prs
        hasLoadedPRs = true
        rateLimit = DemoFixtures.rateLimit
        settings.showRepoTree = true
        layout.expandedSources.insert(Source.org(DemoFixtures.orgLogin).id)
        selectedSource = Source.org(DemoFixtures.orgLogin)
        browsingRepos = true
        connection = .connected
        isStarting = false
    }
#endif

    /// Fetches the repositories of `sources` that are not cached (or whose cache is over five minutes old). Each
    /// source stands alone: results are cached per source, and one source failing is recorded in `repoFailures`
    /// without touching the others.
    func loadRepos(for sources: [Source]) async {
        guard let client else { return }
        let sources = sources.filter { $0.repoId == nil } // a repository source has no repository list of its own
        let now = Date()
        let stale = sources.filter { s in
            !loadingRepoSources.contains(s.id) && (repoCache[s.id].map { now.timeIntervalSince($0.date) > 300 } ?? true)
        }
        guard !stale.isEmpty else { return }
        loadingRepoSources.formUnion(stale.map(\.id))
        defer { loadingRepoSources.subtract(stale.map(\.id)) }
        do {
            let fetched = try await fetchRepoLists(stale, client: client)
            storeRepoLists(fetched.lists)
            publishRepos()
            for l in fetched.lists { repoFailures[l.source.name] = nil }
            for (source, message) in fetched.failures { repoFailures[source.name] = message }
        } catch {} // cancelled
    }

    /// Repositories of the sources shown expanded in the sidebar (restored from the saved layout on launch).
    func loadExpandedRepos() async {
        guard settings.showRepoTree else { return }
        let expanded = catalog.allSources.filter { layout.expandedSources.contains($0.id) }
        await loadRepos(for: expanded)
    }

    /// A source's repositories as shown in the sidebar, newest push first.
    func repos(in source: Source) -> [RepoInfo] {
        let all = repoCache[source.id]?.repos ?? []
        return settings.hideArchivedRepos ? all.filter { !$0.isArchived } : all
    }
    func isTruncated(_ source: Source) -> Bool { repoCache[source.id]?.truncated == true }
    func isExpanded(_ source: Source) -> Bool { layout.expandedSources.contains(source.id) }

    /// Shows or hides a source's repositories, fetching them the first time they are shown.
    func toggleExpanded(_ source: Source) {
        guard settings.showRepoTree, source.repoId == nil else { return }
        if layout.expandedSources.remove(source.id) == nil {
            layout.expandedSources.insert(source.id)
            Task { await loadRepos(for: [source]) }
        }
    }

    private typealias RepoList = (source: Source, repos: [RepoInfo], limits: [RateLimit], truncated: Bool)

    /// Each source succeeds or fails on its own, so one inaccessible org does not hide the others' repositories.
    private func fetchRepoLists(_ sources: [Source], client: GraphQLClient) async throws
        -> (lists: [RepoList], failures: [Source: String]) {
        let outcomes = await withTaskGroup(of: (Source, Swift.Result<RepoList, Error>).self) { group in
            for s in sources {
                group.addTask {
                    do {
                        let r = try await Self.fetchAllRepos(owner: s.name, client: client)
                        return (s, .success((s, r.repos, r.limits, r.truncated)))
                    } catch { return (s, .failure(error)) }
                }
            }
            var out: [(Source, Swift.Result<RepoList, Error>)] = []
            for await r in group { out.append(r) }
            return out
        }
        var lists: [RepoList] = [], failures: [Source: String] = [:]
        for (source, outcome) in outcomes {
            switch outcome {
            case .success(let list): lists.append(list)
            case .failure(let error):
                if error is CancellationError { throw error }
                failures[source] = error.localizedDescription
            }
        }
        return (lists, failures)
    }

    /// Per-source data stays valid whatever the screen is doing now, so it is cached even for a stale request.
    private func storeRepoLists(_ lists: [RepoList]) {
        for l in lists {
            repoCache[l.source.id] = (Date(), l.repos, l.truncated)
            for rl in l.limits { record("Repos: \(l.source.name)", rl) }
        }
    }

    private func publishRepos() {
        repos = repoCache.values.flatMap(\.repos)
    }

    @ObservationIgnored private var repoRefreshToken = 0

    /// Fetches again only the sources whose repository list failed.
    func retryFailedRepos() async {
        guard let client else { return }
        let failed = catalog.allSources.filter { repoFailures[$0.name] != nil }
        guard !failed.isEmpty else { return }
        loadingRepoSources.formUnion(failed.map(\.id))
        defer { loadingRepoSources.subtract(failed.map(\.id)) }
        do {
            let fetched = try await fetchRepoLists(failed, client: client)
            storeRepoLists(fetched.lists)
            publishRepos()
            for l in fetched.lists { repoFailures[l.source.name] = nil }
            for (source, message) in fetched.failures { repoFailures[source.name] = message }
        } catch {}
    }

    /// Re-fetches the repositories that are on screen (counts, permissions, new repos) in place, ignoring the
    /// cache, without touching the selection or the PR list.
    func refreshRepos() async {
        guard let client else { return }
        let shown = catalog.allSources.filter {
            $0.repoId == nil && (layout.expandedSources.contains($0.id) || (showsRepoPane && paneSourceIDs.contains($0.id)))
        }
        guard !shown.isEmpty else { return }
        repoRefreshToken += 1
        let token = repoRefreshToken
        do {
            let fetched = try await fetchRepoLists(shown, client: client)
            storeRepoLists(fetched.lists)
            guard token == repoRefreshToken else { return }
            publishRepos()
            for l in fetched.lists { repoFailures[l.source.name] = nil }
            for (source, message) in fetched.failures { repoFailures[source.name] = message }
            Task { await loadMissingRepoInfo(refresh: true) }
        } catch {}
    }

    /// Every repository of `owner` (archived ones too, which the sidebar marks or hides), newest push first, up to `maxReposPerSource`. Past that the
    /// result is marked truncated so the UI can say so instead of silently dropping the rest.
    private nonisolated static func fetchAllRepos(owner: String, client: GraphQLClient) async throws
        -> (repos: [RepoInfo], limits: [RateLimit], truncated: Bool) {
        var repos: [RepoInfo] = [], limits: [RateLimit] = []
        var after: String?
        var more = false
        repeat {
            let page = try await ReposQuery.fetch(owner: owner, first: 100, after: after, client: client)
            repos += page.repos
            limits.append(page.rateLimit)
            more = page.hasNextPage
            after = more ? page.endCursor : nil
        } while after != nil && repos.count < maxReposPerSource
        return (repos, limits, more)
    }

    /// What a PR load is for. A response is only applied while the screen still asks for the same thing.
    private var loadKey: String {
        destination?.tag ?? ""
    }

    /// Cancels any PR load and forgets its paging, so a late response cannot repopulate the screen.
    private func invalidatePRLoad() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        prCursor = nil
        prPager = nil
        hasMorePRs = false
        prsLoading = false
        prsLoadingMore = false
    }

    private func clearPRs() {
        prs = []; focused = nil; selection.clear(); hasLoadedPRs = false; loadFailed = false; searchShortfall = nil; prFailures = []
    }

    /// The search scopes the current destination is answered with (the inbox has its own shared load).
    private var destinationScopes: [String] {
        switch destination {
        case .sources: SearchScope.chunks(of: activeSources)
        case .search, .savedView:
            { let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines); return q.isEmpty ? [] : [q] }()
        case .inbox, .repo, nil: []
        }
    }

    // MARK: Inbox

    /// Every open PR the viewer wrote or was asked to review, which the six inbox sections are cut from.
    var inboxPRs: [PR] = []
    var inboxLoading = false
    var inboxFailures: [CombinedPager.Failure] = []
    /// More PRs exist than the page cap lets us load.
    var inboxCapped = false
    private(set) var inboxLoaded = false
    @ObservationIgnored private var inboxTask: Task<Void, Never>?
    static let maxInboxPages = 10

    var inboxCounts: [InboxSection: Int] { InboxSection.counts(of: inboxPRs, viewer: viewer?.login ?? "") }

    /// Pages through both inbox searches (author:@me and review-requested:@me), up to `maxInboxPages` pages each.
    /// Overlapping calls share one load. A search that fails is recorded and the other still delivers.
    func loadInbox() async {
        guard let client, viewer != nil else { return }
        if let running = inboxTask { await running.value; return }
        let task = Task { await runInbox(client) }
        inboxTask = task
        await task.value
        inboxTask = nil
    }

    private func runInbox(_ client: GraphQLClient) async {
        inboxLoading = true
        defer { inboxLoading = false }
        var pager = CombinedPager(scopes: InboxSection.searchScopes, explodable: false)
        var all: [PR] = [], limits: [RateLimit] = []
        var rounds = 0
        do {
            repeat {
                let r = try await CombinedPRs.fetchNext(pager, existing: all, skipFailed: true, needsReviewers: true, client: client)
                pager = r.pager; all = r.prs; limits += r.rateLimits
                rounds += 1
            } while pager.pending.contains(where: { pager.chunks[$0].lastError == nil }) && rounds < Self.maxInboxPages
            inboxPRs = all
            inboxFailures = pager.failures
            inboxCapped = pager.pending.contains { pager.chunks[$0].lastError == nil }
            inboxLoaded = true
            for rl in limits { record("Inbox", rl) }
        } catch {
            if error is CancellationError { return }
            inboxFailures = InboxSection.searchScopes.map { .init(scope: $0, message: error.localizedDescription) }
        }
        reapplyInboxIfSelected()
    }

    /// Shows an inbox section: the shared load (reloaded on a refresh) cut down to the PRs that belong to it.
    private func loadInboxDestination(_ section: InboxSection, more: Bool, soft: Bool) {
        if more { return }
        loadTask?.cancel()
        if !soft { clearPRs(); prCursor = nil; prPager = nil; hasMorePRs = false }
        loadGeneration += 1
        let gen = loadGeneration, key = loadKey
        loadFailed = false
        prsLoading = true
        prsLoadingMore = false
        loadTask = Task {
            defer { if gen == loadGeneration { prsLoading = false; prsLoadingMore = false; hasLoadedPRs = true } }
            if soft || !inboxLoaded { await loadInbox() }
            guard !Task.isCancelled, gen == loadGeneration, key == loadKey else { return }
            if !inboxLoaded { loadFailed = true; error = inboxFailures.first?.message; return }
            applyInbox(section, reconcile: soft)
        }
    }

    private func applyInbox(_ section: InboxSection, reconcile: Bool) {
        let viewer = viewer?.login ?? ""
        prs = inboxPRs.filter { InboxSection.classify($0, viewer: viewer) == section }
        hasMorePRs = false
        prFailures = inboxFailures
        searchShortfall = nil
        if reconcile { reconcileWithLoaded() }
    }

    /// A background reload (timer, refresh) changes the selected section's contents in place.
    private func reapplyInboxIfSelected() {
        guard case .inbox(let section) = destination, !prsLoading else { return }
        applyInbox(section, reconcile: true)
        hasLoadedPRs = true
    }

    // MARK: Search counts

    /// Open-PR counts for the quick searches and saved views, by search scope.
    var searchCounts: [String: Int] = [:]
    var searchCountErrors: [String: String] = [:]

    func count(for search: QuickSearch) -> Int? { searchCounts[search.scope] }
    func count(for view: SavedView) -> Int? { searchCounts[view.scope] }

    func loadSearchCounts() async {
        guard let client else { return }
        var scopes = layout.visibleSearches.map(\.scope) + layout.visibleViews.map(\.scope)
        scopes = scopes.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard !scopes.isEmpty, let fetched = try? await SearchCounts.fetch(scopes, client: client) else { return }
        searchCounts.merge(fetched.result.counts) { $1 }
        searchCountErrors = fetched.result.errors
        for rl in fetched.rateLimits { record("Search counts", rl) }
    }

    // MARK: Saved views

    /// Adds a view and opens it.
    @discardableResult
    func saveView(name: String, query: String) throws -> SavedView {
        let v = try SavedView.validate(name: name, query: query, among: layout.savedViews)
        let view = SavedView(name: v.name, query: v.query)
        layout.savedViews.append(view)
        layout.savedViewsHidden = false
        destination = .savedView(view.id)
        Task { await loadSearchCounts() }
        return view
    }

    func updateView(_ id: UUID, name: String, query: String) throws {
        let v = try SavedView.validate(name: name, query: query, among: layout.savedViews, editing: id)
        guard let i = layout.savedViews.firstIndex(where: { $0.id == id }) else { return }
        let queryChanged = layout.savedViews[i].query != v.query
        layout.savedViews[i].name = v.name
        layout.savedViews[i].query = v.query
        if queryChanged {
            if destination == .savedView(id) { searchText = v.query; loadPRs() }
            Task { await loadSearchCounts() }
        }
    }

    func deleteView(_ id: UUID) {
        layout.savedViews.removeAll { $0.id == id }
        layout.hiddenEntries.remove(SidebarDestination.savedView(id).tag)
        layoutChanged()
    }

    func setSavedViewsHidden(_ hidden: Bool) {
        layout.savedViewsHidden = hidden
        layoutChanged()
    }

    /// How many open PRs a query matches, or why GitHub would not run it. Used by the view editor as you type.
    func previewCount(for query: String) async -> (count: Int?, error: String?) {
        guard let client else { return (nil, "Not connected to GitHub") }
        let scope = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scope.isEmpty else { return (nil, nil) }
        do {
            let r = try await SearchCounts.fetch([scope], client: client).result
            return (r.counts[scope], r.errors[scope])
        } catch { return (nil, error.localizedDescription) }
    }

    // MARK: Hiding

    /// Hides or shows the whole Inbox block, with its queries.
    func setInboxHidden(_ hidden: Bool) {
        layout.inboxHidden = hidden
        layoutChanged()
    }

    func setQuickSearchesHidden(_ hidden: Bool) {
        layout.quickSearchesHidden = hidden
        layoutChanged()
    }

    func hideEntry(_ tag: String) {
        layout.hiddenEntries.insert(tag)
        layoutChanged()
    }

    func showHiddenEntries() {
        layout.hiddenEntries = []
        layoutChanged()
    }

    /// Blocks and entries hidden at the top of the sidebar (the Inbox, the shortcuts, saved views, single entries).
    var hiddenSidebarCount: Int {
        (layout.inboxHidden ? 1 : 0) + (layout.quickSearchesHidden ? 1 : 0) + (layout.savedViewsHidden ? 1 : 0)
            + layout.hiddenEntries.count
    }

    /// Brings back everything hidden at the top of the sidebar. Saved views themselves are never touched.
    func showAllSidebarItems() {
        layout.inboxHidden = false
        layout.quickSearchesHidden = false
        layout.savedViewsHidden = false
        layout.hiddenEntries = []
        layoutChanged()
    }

    /// A destination that was just hidden cannot stay selected: fall back to the first visible source.
    private func layoutChanged() {
        if let d = destination, !layout.shows(d) {
            destination = nil
            selectedSource = sources.first
        }
        if layout.needsInboxData, !inboxLoaded { Task { await loadInbox() } }
        Task { await loadSearchCounts() }
    }

    /// Loads the open PRs of the selected repository, or of every selected source.
    /// `more` appends the next page; `soft` keeps the current list on screen while refetching.
    func loadPRs(more: Bool = false, soft: Bool = false, onlyFailed: Bool = false) {
        guard let client else { return }
        if case .inbox(let section) = destination { loadInboxDestination(section, more: more, soft: soft); return }
        if showsRepoPane { Task { await loadRepos(for: paneSources) } }
        if case .sources = destination, showsRepoPane {
            // Repos view with no repository chosen yet: the pane lists them and there are no PRs to load.
            if !more && !soft { invalidatePRLoad(); clearPRs() }
            lastLoadedQuery = nil
            return
        }
        let repo = selectedRepo, active = activeSources, scopes = destinationScopes
        if isSearchDestination { lastLoadedQuery = scopes.first; searchError = nil }
        if repo == nil && scopes.isEmpty {
            // Nothing to show: drop whatever was loading for the previous selection rather than leave it running.
            if !more && !soft { invalidatePRLoad(); clearPRs() }
            lastLoadedQuery = nil
            return
        }
        // The next page continues the loaded first page: it cannot run while that page is loading or reloading,
        // while another page is in flight, or when there is nothing further. Otherwise it would bump the
        // generation, discard the refresh, and fetch page one again to append to stale data.
        if more && (prsLoading || prsLoadingMore || !hasMorePRs) { return }
        let key = loadKey
        if !more {
            loadTask?.cancel()
            // A soft refresh keeps the list, cursor and pager until the new first page replaces them, so a
            // failed refresh leaves paging consistent with what is on screen.
            if !soft { clearPRs(); prCursor = nil; prPager = nil; hasMorePRs = false }
        }
        loadGeneration += 1
        let gen = loadGeneration
        let cursor = more ? prCursor : nil
        let pager = more ? prPager : nil
        let existing = more ? prs : []
        // A refresh re-reads as many pages as were on screen, so what the user had loaded (and selected or
        // focused) is still there afterwards instead of collapsing back to page one.
        let reloadCount = (soft && !more) ? prs.count : 0
        loadFailed = false
        prsLoading = !more
        prsLoadingMore = more
        loadTask = Task {
            // only the newest load may clear the flags, so a cancelled one cannot hide a live spinner
            defer { if gen == loadGeneration { prsLoading = false; prsLoadingMore = false; hasLoadedPRs = true } }
            do {
                if repo == nil {
                    let start = pager ?? CombinedPager(scopes: scopes, explodable: !isSearchDestination)
                    var result = try await CombinedPRs.fetchNext(start, existing: existing, onlyFailed: onlyFailed, client: client)
                    var limits = result.rateLimits
                    var extra = 0
                    while result.prs.count < reloadCount, result.pager.hasMore, result.failures.isEmpty, extra < Self.maxRefreshPages, !Task.isCancelled {
                        result = try await CombinedPRs.fetchNext(result.pager, existing: result.prs, client: client)
                        limits += result.rateLimits
                        extra += 1
                    }
                    // stale-response guard: the user may have moved on while this was in flight
                    guard !Task.isCancelled, gen == loadGeneration, key == loadKey else { return }
                    prs = result.prs // CombinedPager.merge keeps one entry per PR
                    prPager = result.pager
                    hasMorePRs = result.pager.hasMore
                    prFailures = result.failures
                    searchShortfall = result.pager.isIncomplete ? (result.pager.receivedMatches, result.pager.totalMatches) : nil
                    let label = scopes.count == 1 ? "PRs: \(scopes[0])" : "PRs: \(active.count) sources"
                    for rl in limits { record(label, rl) }
                    if reloadCount > 0 { reconcileWithLoaded() }
                } else if let repo {
                    var page = try await PullRequestQuery.fetchRepo(repo, after: cursor, client: client)
                    var loaded = page.prs
                    var limits = [page.rateLimit]
                    var extra = 0
                    while loaded.count < reloadCount, page.hasNextPage, extra < Self.maxRefreshPages, !Task.isCancelled {
                        page = try await PullRequestQuery.fetchRepo(repo, after: page.endCursor, client: client)
                        loaded += page.prs
                        limits.append(page.rateLimit)
                        extra += 1
                    }
                    guard !Task.isCancelled, gen == loadGeneration, key == loadKey else { return }
                    if more {
                        let seen = Set(prs.map(\.id))
                        prs += loaded.filter { !seen.contains($0.id) }
                    } else {
                        var seen = Set<PrId>()
                        prs = loaded.filter { seen.insert($0.id).inserted }
                    }
                    prCursor = page.endCursor
                    hasMorePRs = page.hasNextPage
                    for rl in limits { record("PRs: \(repo.fullName)", rl) }
                    if reloadCount > 0 { reconcileWithLoaded() }
                }
                error = nil
                Task { await loadMissingRepoInfo() }
            } catch {
                if !Task.isCancelled, gen == loadGeneration {
                    // A search being typed is often briefly invalid: say so beside the box, not in an alert.
                    if isSearchDestination { searchError = error.localizedDescription }
                    else { self.error = error.localizedDescription; loadFailed = true }
                }
            }
        }
    }

    static let maxRefreshPages = 10

    /// After a refresh, drops selected or focused PRs that are no longer in the list (merged or closed meanwhile),
    /// so the selection bar, its targets and the detail pane agree with what is shown.
    private func reconcileWithLoaded() {
        let present = Set(prs.map(\.id))
        selection.deselect(selection.selected.subtracting(present))
        if let f = focused, !present.contains(f) { focused = nil }
    }

    /// What the PR list should say when it has nothing to show, or nil while it has rows or is still loading.
    enum ListEmptyState: Equatable { case failed, noOpenPRs, noMatches }

    var listEmptyState: ListEmptyState? {
        guard hasLoadedPRs, !prsLoading, visiblePRs.isEmpty else { return nil }
        if prs.isEmpty { return loadFailed ? .failed : .noOpenPRs }
        return .noMatches // PRs exist, but the filter hides every one of them
    }

    /// How a PR is named in the list: `#12` inside one repository, `repo#12` within one source, otherwise
    /// `owner/repo#12`, since the list can then mix owners.
    func label(for pr: PR) -> String {
        if case .repo = destination { return "#\(pr.number)" }
        let single: Bool = { if case .sources = destination { return !isCombined } else { return false } }()
        return "\(single ? pr.repo.name : pr.repo.fullName)#\(pr.number)"
    }

    /// Filters and sorting only see the PRs loaded so far; true while more pages exist that they cannot see.
    var viewIsPartial: Bool { hasMorePRs && (isFiltering || sort != .newest) }

    var loadingAllPRs = false

    /// Loads every remaining page (up to `maxPages`) so a filter or sort covers all PRs. Stops if the user
    /// navigates elsewhere or a page fails.
    func loadAllPRs(maxPages: Int = 50) async {
        guard !loadingAllPRs else { return }
        loadingAllPRs = true
        defer { loadingAllPRs = false }
        let key = loadKey
        var pages = 0
        while hasMorePRs, pages < maxPages, key == loadKey {
            if prsLoading || prsLoadingMore {
                await loadTask?.value
                if prsLoading || prsLoadingMore { try? await Task.sleep(for: .milliseconds(20)) }
                continue
            }
            loadPRs(more: true)
            await loadTask?.value
            pages += 1
            if loadFailed { break }
        }
    }

    /// Retries only the sources that failed, keeping everything already loaded.
    func retryFailedSources() {
        if destination?.isInbox == true { Task { await loadInbox() }; return } // the inbox reloads whole; it is two searches
        loadPRs(more: true, onlyFailed: true)
    }

    func refresh() {
        // Not connected: the normal refresh control reconnects instead of silently doing nothing.
        guard connection == .connected else { Task { await start() }; return }
        Task { _ = await accountMatches() } // another `gh` login must not be used silently
        Task { await loadCounts() }
        Task { await loadSearchCounts() }
        Task { await refreshRepos() }
        if layout.needsInboxData, !destination.map(\.isInbox).orFalse { Task { await loadInbox() } }
        loadPRs(soft: true)
    }

    // MARK: API usage

    /// Remembers the latest rate limit and logs what the query cost.
    func record(_ label: String, _ rl: RateLimit) {
        rateLimit = rl
        requestLog.record(label, rl)
    }

    /// `gh api rate_limit` is free, so it is safe to call whenever the usage panel opens.
    func loadRateBuckets() async {
        guard let gh else { return }
        if let buckets = try? await RateLimitAPI.fetchBuckets(gh: gh) { rateBuckets = buckets }
        rateBucketsLoaded = true
    }

    // MARK: Diffs

    /// Keyed by head commit and base branch: a push or a retarget produces a new key, and the stored diff is
    /// fetched for exactly that comparison.
    func diffKey(_ pr: PR) -> String { DiffFetcher.identity(pr) }

    func loadDiff(_ pr: PR, force: Bool = false) async {
        guard let gh else { return }
        let key = diffKey(pr)
        if !force, diffs[key] != nil { return }
        if diffs.count > 30 { diffs = diffs.filter { $0.key == key } }
        diffs[key] = .loading
        do {
            let result = try await DiffFetcher.fetchResult(pr, gh: gh)
            diffs[key] = .loaded(result.files)
            if result.usedCurrentDiff { refresh() }
        } catch { diffs[key] = .failed(error.localizedDescription) }
    }

    // MARK: Activity (description, comments, reviews)

    /// Keyed by `updatedAt` so a list refresh that sees new activity refetches it.
    func activityKey(_ pr: PR) -> String { "\(pr.repo.fullName)#\(pr.number)@\(pr.updatedAt.timeIntervalSince1970)" }

    func loadActivity(_ pr: PR, force: Bool = false) async {
        guard let client else { return }
        let key = activityKey(pr)
        if !force, activities[key] != nil { return }
        if activities.count > 30 { activities = activities.filter { $0.key == key } }
        // Keep showing the old content while a forced reload runs.
        if case .loaded = activities[key] {} else { activities[key] = .loading }
        do {
            let activity = try await ActivityQuery.fetch(pr.id, client: client)
            if let rl = activity.rateLimit { record("Conversation: \(pr.repo.name)#\(pr.number)", rl) }
            activities[key] = .loaded(activity)
        }
        catch { activities[key] = .failed(error.localizedDescription) }
    }

    // MARK: Checks (individual check runs, shown in the detail view)

    /// Keyed by head commit: a new push produces a new key, so the stored checks are refetched for it.
    func checksKey(_ pr: PR) -> String { "\(pr.repo.fullName)#\(pr.number)@\(pr.headSha)" }

    func loadChecks(_ pr: PR, force: Bool = false) async {
        guard let client else { return }
        let key = checksKey(pr)
        if !force, checkRuns[key] != nil { return }
        // The rollup's combined state (always present) is unknown only when there are no checks at all: nothing
        // to fetch.
        guard pr.checkSummary != .unknown else { checkRuns[key] = .loaded(checks: [], counts: CheckCounts()); return }
        if checkRuns.count > 30 { checkRuns = checkRuns.filter { $0.key == key } }
        if case .loaded = checkRuns[key] {} else { checkRuns[key] = .loading }
        do {
            let (runs, counts, rl) = try await ChecksQuery.fetch(pr.id, client: client)
            record("Checks: \(pr.repo.name)#\(pr.number)", rl)
            checkRuns[key] = .loaded(checks: runs, counts: counts)
        } catch { checkRuns[key] = .failed(error.localizedDescription) }
    }

    // MARK: Reviewers (who was asked to review, shown in the detail view)

    /// Keyed like activity: a new review request bumps `updatedAt` the same as any other change to the PR.
    func loadReviewers(_ pr: PR, force: Bool = false) async {
        guard let client else { return }
        // Already carried on the PR itself (the inbox's review-requested search fetches it eagerly).
        if !force, !pr.requestedReviewers.isEmpty || !pr.requestedTeams.isEmpty { return }
        let key = activityKey(pr)
        if !force, reviewRequests[key] != nil { return }
        if reviewRequests.count > 30 { reviewRequests = reviewRequests.filter { $0.key == key } }
        if case .loaded = reviewRequests[key] {} else { reviewRequests[key] = .loading }
        do {
            let (reviewers, teams, rl) = try await ReviewersQuery.fetch(pr.id, client: client)
            record("Reviewers: \(pr.repo.name)#\(pr.number)", rl)
            reviewRequests[key] = .loaded(reviewers: reviewers, teams: teams)
        } catch { reviewRequests[key] = .failed(error.localizedDescription) }
    }

    /// Unsent comments, per PR. They live here rather than in the composer view so visiting another PR or tab
    /// does not lose them, and so a post that finishes late updates the PR it was for, not the one on screen.
    var drafts: [PrId: CommentDraft] = [:]

    func draftText(for id: PrId) -> String { drafts[id]?.text ?? "" }

    func setDraftText(_ text: String, for id: PrId) {
        if text.isEmpty, drafts[id]?.posting != true { drafts[id] = nil } else { drafts[id, default: CommentDraft()].text = text }
    }

    /// Posts the draft for `pr`. The draft is cleared only if this exact post succeeds; on failure it is kept
    /// with the error. Reloading the conversation afterwards cannot fail the post.
    func postDraft(for pr: PR) async {
        let id = pr.id
        guard let draft = drafts[id], !draft.posting else { return }
        let body = draft.text
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafts[id]?.posting = true
        drafts[id]?.error = nil
        do {
            try await postComment(body, on: pr)
            if drafts[id]?.text == body { drafts[id] = nil } else { drafts[id]?.posting = false }
        } catch {
            drafts[id]?.posting = false
            drafts[id]?.error = error.localizedDescription
            return
        }
        await loadActivity(pr, force: true)
    }

    /// Posts a comment; throws so the caller can keep the draft on failure.
    func postComment(_ text: String, on pr: PR) async throws {
        guard let actions else { return }
        try await actions.postComment(text, on: pr)
    }

    // MARK: Source counts

    /// Several small, concurrent GraphQL requests (1 point each) rather than one big one, so a gateway hiccup on
    /// a big catalog only misses a few sources' counts instead of failing the whole refresh. Whatever does not
    /// come back this round keeps its last known number.
    func loadCounts() async {
        guard let client, !countsLoading else { return }
        let sources = catalog.allSources
        guard !sources.isEmpty else { return }
        countsLoading = true; defer { countsLoading = false }
        let (fresh, limits) = await SourceCountsQuery.fetch(sources, client: client)
        guard !fresh.isEmpty else { return } // every batch failed; the badges are a convenience and must not interrupt anything
        counts.merge(fresh) { _, new in new }
        countedIDs.formUnion(fresh.keys)
        SourceCountsCache.save(counts, to: countsURL)
        catalog.updateAutoHidden(counts: counts, keeping: selectedSourceIDs)
        persistSources()
        for rl in limits { record("Source counts (\(sources.count))", rl) }
    }

    /// Every five minutes while the app is frontmost: about 12 points an hour.
    private func startCountsTimer() {
        countsTimer?.cancel()
        countsTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if NSApplication.shared.isActive {
                    await self?.loadCounts(); await self?.refreshRepos(); await self?.loadSearchCounts()
                    if self?.layout.needsInboxData == true { await self?.loadInbox() }
                }
            }
        }
    }

    func totals(for sources: [Source]) -> SourceCounts {
        sources.reduce(into: SourceCounts()) { sum, s in
            if let c = counts[s.id], c.error == nil { sum.open += c.open; sum.reviewRequested += c.reviewRequested }
        }
    }

    // MARK: Sources editing

    private func persistSources() {
        catalog.save(to: defaults, key: catalogKey)
        if Set(catalog.allSources.map(\.id)) != countedIDs { Task { await loadCounts() } } // sources added or removed
        selectedSourceIDs.formIntersection(Set(sources.map(\.id)))   // hidden or deleted sources leave the selection
        if destination == nil, let first = sources.first { selectedSource = first }
    }

    /// Validates and looks a login up on GitHub (one REST call). Used by the add dialog's live preview.
    func lookupSource(_ rawName: String) async throws -> SourceProfile {
        guard let gh else { throw SourceCatalog.EditError.notFound(rawName) }
        return try await SourcesQuery.profile(name: try SourceCatalog.validate(rawName), gh: gh)
    }

    /// `resolved` is a lookup the dialog already did for this name, which saves a second request.
    func addSource(_ rawName: String, group: UUID? = nil, resolved: Source? = nil) async throws {
        guard let gh else { return }
        let name = try SourceCatalog.validate(rawName)
        if catalog.contains(name) { throw SourceCatalog.EditError.duplicate(name) }
        let source: Source
        if let resolved, resolved.name.caseInsensitiveCompare(name) == .orderedSame { source = resolved }
        else { source = try await SourcesQuery.resolve(name: name, gh: gh) }
        try catalog.add(source, to: group)
        persistSources()
        selectedSource = source
    }

    func updateSource(_ old: Source, to rawName: String, resolved: Source? = nil) async throws {
        guard let gh else { return }
        let name = try SourceCatalog.validate(rawName)
        if name == old.name { return }
        let new: Source
        if let resolved, resolved.name.caseInsensitiveCompare(name) == .orderedSame { new = resolved }
        else { new = try await SourcesQuery.resolve(name: name, gh: gh) }
        try catalog.replace(old, with: new)
        if selectedSourceIDs.remove(old.id) != nil { selectedSourceIDs.insert(new.id) }
        persistSources()
    }

    /// Adds one repository as a source (the "Add to Sources" menu item), without navigating away from what is open.
    func addRepoSource(_ repo: RepoId) {
        let source = Source.repo(repo.fullName)
        do {
            try catalog.add(source)
            persistSources()
            Task { await loadMissingRepoInfo() }
            Task { await loadCounts() }
        } catch {}
    }

    func isSource(_ repo: RepoId) -> Bool { catalog.contains(repo.fullName) }

    func removeSources(_ removed: [Source]) { catalog.remove(removed); persistSources() }
    /// Offsets index what the sidebar shows (the group's visible sources).
    func removeSources(inGroup id: UUID, atOffsets offsets: IndexSet) { catalog.removeVisible(inGroup: id, atOffsets: offsets); persistSources() }

    func isSourceHidden(_ s: Source) -> Bool { catalog.isHidden(s) }
    func setSourcesHidden(_ list: [Source], _ hide: Bool) { catalog.setHidden(list, hide); persistSources() }
    func setGroupHidden(_ id: UUID, _ hide: Bool) { catalog.setGroupHidden(id, hide); persistSources() }
    func showOnlySources(_ list: [Source]) { catalog.showOnly(list); persistSources() }
    func showAllSources() { catalog.showAll(); persistSources() }
    func hideAllOrganizations() {
        catalog.setHidden(catalog.allSources.filter { if case .org = $0 { true } else { false } }, true)
        persistSources()
    }
    func sortSources(_ order: SourceCatalog.SortOrder, group: UUID? = nil) { catalog.sort(order, group: group); persistSources() }

    // Groups

    func createGroup(_ name: String) throws { try catalog.createGroup(name: name); persistSources() }
    func renameGroup(_ id: UUID, to name: String) throws { try catalog.renameGroup(id, to: name); persistSources() }
    func deleteGroup(_ id: UUID) throws { try catalog.deleteGroup(id); persistSources() }
    func setGroupCollapsed(_ id: UUID, _ collapsed: Bool) { catalog.setCollapsed(id, collapsed); persistSources() }
    func moveSources(_ list: [Source], toGroup id: UUID) { catalog.move(list, toGroup: id); persistSources() }

    /// A source dropped on a row goes before that row; on a header it goes to the end of the group.
    func dropSources(ids: [String], onto target: Source?, inGroup id: UUID) {
        let moving = ids.compactMap { catalog.source(withID: $0) }
        let index = target.flatMap { t in catalog.group(withID: id)?.sources.firstIndex(of: t) }
        catalog.move(moving, toGroup: id, at: index)
        persistSources()
    }

    /// A group dropped on another group's header goes before it.
    func dropGroup(_ dragged: UUID, before target: UUID) {
        guard dragged != target,
              let from = catalog.groups.firstIndex(where: { $0.id == dragged }),
              let to = catalog.groups.firstIndex(where: { $0.id == target }) else { return }
        catalog.moveGroups(fromOffsets: [from], toOffset: to)
        persistSources()
    }

    var missingOrgs: [String] { viewer.map { catalog.missingOrgs(for: $0) } ?? [] }

    func addMissingOrgs() {
        for org in missingOrgs { try? catalog.add(.org(org)) }
        persistSources()
    }

    // Smarter hiding

    var newOrgCount: Int { catalog.newCount }

    func setAutoHideEmpty(_ on: Bool) {
        catalog.settings.autoHideEmpty = on
        catalog.updateAutoHidden(counts: counts, keeping: selectedSourceIDs)
        persistSources()
    }

    func setNewOrgPolicy(_ policy: SourceSettings.NewOrgPolicy) {
        catalog.settings.newOrgPolicy = policy
        persistSources()
    }

    /// Shows every org flagged new.
    func showNewSources() {
        catalog.setHidden(catalog.allSources.filter(catalog.isNew), false)
        persistSources()
    }

    func markNewSourcesSeen() { catalog.markAllSeen(); persistSources() }

    func resetSources() {
        guard let viewer else { return }
        showAllSidebarItems()
        catalog = SourceCatalog.seeded(from: SourcesQuery.assemble(viewer: viewer, config: SourceConfig()))
        persistSources()
        selectedSource = sources.first
    }

    // MARK: Actions

    /// Why `action` cannot run on any of `targets`, or nil if it can run on at least one.
    /// Used to disable buttons and explain it in the tooltip; batches still skip individual no-ops.
    func unavailableReason(_ action: PrAction, for targets: [PR]) -> String? {
        guard let viewer else { return "Not signed in" }
        if targets.isEmpty { return "No PR selected" }
        if isBusy(targets) { return "Another action is still running on this PR" }
        let options = ActionOptions(mergeMethod: mergeMethod)
        var first: String?
        for pr in targets {
            let ctx = ActionContext(viewerLogin: viewer.login, repo: repoInfo(for: pr.repo))
            var reason = Permissions.denial(action, pr: pr, ctx: ctx) ?? Permissions.noOp(action, pr: pr, options: options, ctx: ctx)
            if reason == nil { return nil }
            // A failed permissions lookup is not a denial, and the message should not claim one.
            if reason == Permissions.unknownPermissions(pr), failedRepoInfo.contains(pr.repo) {
                reason = "Could not load permissions for \(pr.repo.fullName)"
            }
            first = first ?? reason
        }
        return targets.count > 1 ? "Not applicable to any selected PR (\(first ?? ""))" : first
    }

    /// Whether to show `action` at all. A button that cannot work (no push access, a draft, not open, auto-merge
    /// off for the repo) is left out rather than shown disabled. While the answer is still coming (another action
    /// running, permissions not loaded yet or failed to load) it stays, disabled, so controls do not flicker in.
    func offers(_ action: PrAction, for targets: [PR]) -> Bool {
        guard let reason = unavailableReason(action, for: targets) else { return true }
        return ["still running", "not loaded yet", "Could not load permissions", "Not signed in"].contains { reason.contains($0) }
    }

    /// Selected PRs the filter currently hides. A batch still includes them.
    var hiddenSelectedCount: Int { selection.hidden(from: visiblePRs.map(\.id)).count }

    /// Targets the action would really run on (not denied, not a no-op).
    private func runnable(_ action: PrAction, in targets: [PR]) -> [PR] {
        guard let viewer else { return [] }
        let options = ActionOptions(mergeMethod: mergeMethod)
        return targets.filter { pr in
            let ctx = ActionContext(viewerLogin: viewer.login, repo: repoInfo(for: pr.repo))
            return Permissions.denial(action, pr: pr, ctx: ctx) == nil && Permissions.noOp(action, pr: pr, options: options, ctx: ctx) == nil
        }
    }

    func isBusy(_ targets: [PR]) -> Bool { targets.contains { busy.contains($0.id) } }

    /// Runs `action`, after asking the user to confirm when a merge or close covers several PRs.
    func perform(_ action: PrAction, on targets: [PR], confirmed: Bool = false) {
        if !confirmed, [.merge, .autoMerge, .close].contains(action) {
            let will = runnable(action, in: targets.filter { !busy.contains($0.id) })
            if will.count > 1 {
                pendingConfirmation = PendingAction(action: action, targets: will,
                                                    methods: Dictionary(uniqueKeysWithValues: will.compactMap { pr in method(for: pr).map { (pr.id, $0) } }))
                return
            }
        }
        guard let actions, let viewer else { return }
        // A PR with an action already running is skipped: a double click must not submit twice.
        let fresh = targets.filter { !busy.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let options = ActionOptions(mergeMethod: mergeMethod)
        let infos = Dictionary(fresh.compactMap { pr in repoInfo(for: pr.repo).map { (pr.repo, $0) } }) { a, _ in a }
        let ids = fresh.map(\.id)
        busy.formUnion(ids)
        let total = fresh.count
        batchProgress = BatchProgress(done: 0, total: total)
        Task {
            defer { busy.subtract(ids); batchProgress = nil }
            guard await accountMatches() else { return }
            let summary = await BatchRunner.run(action, on: fresh, actions: actions, options: options, progress: { done in
                Task { @MainActor in if self.busy.isSuperset(of: ids) { self.batchProgress = BatchProgress(done: done, total: total) } }
            }) { pr in
                ActionContext(viewerLogin: viewer.login, repo: infos[pr.repo])
            }
            // The selection and the list are left as they are: the user clears the selection and refreshes.
            if !summary.failed.isEmpty { error = summary.failed.joined(separator: "\n") }
        }
    }

    func confirmPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        perform(pending.action, on: pending.targets, confirmed: true)
    }

    /// Sends a `@dependabot` command to each Dependabot PR. Failures are reported; the selection is left as it is.
    func dependabot(_ command: String, on targets: [PR]) {
        guard let actions else { return }
        let bots = targets.filter(\.isDependabot).filter { !busy.contains($0.id) }
        guard !bots.isEmpty else { return }
        let ids = bots.map(\.id)
        busy.formUnion(ids)
        batchProgress = BatchProgress(done: 0, total: bots.count)
        Task {
            defer { busy.subtract(ids); batchProgress = nil }
            guard await accountMatches() else { return }
            let summary = await BatchRunner.comment(Dependabot.comment(command), on: bots, actions: actions)
            if !summary.failed.isEmpty { error = summary.failed.joined(separator: "\n") }
        }
    }

    func open(_ source: Source, pullRequests: Bool = false) {
        NSWorkspace.shared.open(pullRequests ? source.pullRequestsURL : source.profileURL)
    }

    func open(_ repo: RepoId, pullRequests: Bool = false) {
        NSWorkspace.shared.open(pullRequests ? repo.pullRequestsURL : repo.url)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ prs: [PR]) {
        for pr in prs { if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) } }
    }

    func copyURLs(_ prs: [PR]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prs.map(\.url).joined(separator: "\n"), forType: .string)
    }

    /// What a right-click menu acts on. By default only the PR that was clicked, even when it is one of several
    /// selected; with the setting on, a click on a selected PR acts on the whole selection.
    func contextTargets(for pr: PR) -> [PR] {
        guard settings.contextMenuScope == .allSelected, selection.selected.contains(pr.id) else { return [pr] }
        return selection.targets(in: prs)
    }

    /// Selected PRs if any are checked, otherwise just the focused one.
    var actionTargets: [PR] {
        selection.isSelectionMode ? selection.targets(in: prs) : (focusedPR.map { [$0] } ?? [])
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
