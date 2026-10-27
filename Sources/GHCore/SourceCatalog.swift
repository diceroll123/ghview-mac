import Foundation

public struct SourceSettings: Codable, Sendable, Equatable {
    public enum NewOrgPolicy: String, Codable, Sendable, CaseIterable { case hidden, visible }
    /// What happens to an org discovered after setup.
    public var newOrgPolicy: NewOrgPolicy = .hidden
    /// Hide sources that currently have no open PRs.
    public var autoHideEmpty = false
    public init(newOrgPolicy: NewOrgPolicy = .hidden, autoHideEmpty: Bool = false) {
        self.newOrgPolicy = newOrgPolicy
        self.autoHideEmpty = autoHideEmpty
    }
}

public struct SourceGroup: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isCollapsed: Bool
    /// Sidebar order. Hidden sources stay here, in their slot.
    public var sources: [Source]

    public init(id: UUID = UUID(), name: String, isCollapsed: Bool = false, sources: [Source] = []) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.sources = sources
    }
}

/// The user's sources, organised into named groups. Every source lives in exactly one group.
/// Hiding never removes anything; removing a source also remembers it so it is not rediscovered later.
public struct SourceCatalog: Codable, Sendable, Equatable {
    public private(set) var groups: [SourceGroup]
    /// `Source.id`s (lowercased names) hidden from the sidebar.
    public private(set) var hidden: Set<String>
    /// Sources the user deleted on purpose.
    public private(set) var dismissed: Set<String>
    /// Orgs found after setup that the user has not looked at yet.
    public private(set) var newlyDiscovered: Set<String>
    /// Sources the user explicitly showed, which the auto-hide rule must leave alone.
    public private(set) var forceShown: Set<String>
    public var settings: SourceSettings
    /// Sources hidden by the empty-source rule. Derived from the latest counts, so it is never saved.
    public private(set) var autoHidden: Set<String> = []

    public init(groups: [SourceGroup] = [], hidden: Set<String> = [], dismissed: Set<String> = [],
                newlyDiscovered: Set<String> = [], forceShown: Set<String> = [], settings: SourceSettings = SourceSettings()) {
        self.groups = groups
        self.hidden = hidden
        self.dismissed = dismissed
        self.newlyDiscovered = newlyDiscovered
        self.forceShown = forceShown
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case groups, hidden, dismissed, newlyDiscovered, forceShown, settings }

    /// Keys added over time are optional, so a catalog saved by an earlier build still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decode([SourceGroup].self, forKey: .groups)
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        dismissed = try c.decodeIfPresent(Set<String>.self, forKey: .dismissed) ?? []
        newlyDiscovered = try c.decodeIfPresent(Set<String>.self, forKey: .newlyDiscovered) ?? []
        forceShown = try c.decodeIfPresent(Set<String>.self, forKey: .forceShown) ?? []
        settings = try c.decodeIfPresent(SourceSettings.self, forKey: .settings) ?? SourceSettings()
    }

    public enum EditError: Error, LocalizedError, Equatable {
        case empty, invalidName(String), duplicate(String), notFound(String)
        case emptyGroupName, duplicateGroup(String), lastGroup
        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a username, an organization or owner/repo"
            case .invalidName(let n): "\"\(n)\" is not a valid GitHub name"
            case .duplicate(let n): "\(n) is already in the list"
            case .notFound(let n): "No GitHub user, organization or repository named \(n)"
            case .emptyGroupName: "Enter a group name"
            case .duplicateGroup(let n): "A group named \"\(n)\" already exists"
            case .lastGroup: "You need at least one group"
            }
        }
    }

    public static let accountsGroupName = "Accounts"
    public static let organizationsGroupName = "Organizations"
    public static let repositoriesGroupName = "Repositories"

    // MARK: Construction

    /// Fresh install: users in "Accounts", orgs in "Organizations", in the given order.
    public static func seeded(from sources: [Source]) -> SourceCatalog {
        var accounts = SourceGroup(name: accountsGroupName), orgs = SourceGroup(name: organizationsGroupName)
        var repos = SourceGroup(name: repositoriesGroupName)
        for s in sources {
            switch s {
            case .user: accounts.sources.append(s)
            case .org: orgs.sources.append(s)
            case .repo: repos.sources.append(s)
            }
        }
        return SourceCatalog(groups: repos.sources.isEmpty ? [accounts, orgs] : [accounts, orgs, repos])
    }

    // MARK: Queries

    public var allSources: [Source] { groups.flatMap(\.sources) }
    public var visibleSources: [Source] { allSources.filter { !isHidden($0) } }
    public var hiddenCount: Int { allSources.filter(isHidden).count }
    public func visibleSources(in group: SourceGroup) -> [Source] { group.sources.filter { !isHidden($0) } }
    /// Hidden by hand or by the empty-source rule.
    public func isHidden(_ s: Source) -> Bool { hidden.contains(s.id) || autoHidden.contains(s.id) }
    public func isAutoHidden(_ s: Source) -> Bool { autoHidden.contains(s.id) && !hidden.contains(s.id) }
    public func isNew(_ s: Source) -> Bool { newlyDiscovered.contains(s.id) }
    public var newCount: Int { allSources.filter(isNew).count }
    public func group(withID id: UUID) -> SourceGroup? { groups.first { $0.id == id } }
    public func group(containing s: Source) -> SourceGroup? { groups.first { $0.sources.contains(s) } }
    public func source(withID id: String) -> Source? { allSources.first { $0.id == id.lowercased() } }

    public func contains(_ name: String) -> Bool {
        allSources.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Orgs the viewer belongs to that are not in the catalog yet (including ones the user deleted).
    public func missingOrgs(for viewer: Viewer) -> [String] {
        viewer.orgs.filter { !contains($0) }.sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: Validation

    static let loginPattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$"#

    /// A GitHub login (alphanumerics and single hyphens, no leading or trailing hyphen, up to 39 chars), or a
    /// repository as `owner/name` (name: letters, digits, `.`, `_`, `-`, up to 100, and not `.` or `..`).
    /// A GitHub URL to a repository is accepted too.
    public static func validate(_ raw: String) throws -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        while name.hasSuffix("/") { name.removeLast() }
        if name.hasSuffix(".git") { name.removeLast(4) }
        if name.isEmpty { throw EditError.empty }
        if name.contains("/") {
            let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  parts[0].range(of: loginPattern, options: .regularExpression) != nil,
                  parts[1].range(of: #"^[A-Za-z0-9._-]{1,100}$"#, options: .regularExpression) != nil,
                  parts[1] != ".", parts[1] != ".." else { throw EditError.invalidName(name) }
            return name
        }
        guard name.range(of: loginPattern, options: .regularExpression) != nil else { throw EditError.invalidName(name) }
        return name
    }

    func validateGroupName(_ raw: String, excluding id: UUID? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw EditError.emptyGroupName }
        if groups.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw EditError.duplicateGroup(name)
        }
        return name
    }

    // MARK: Groups

    @discardableResult
    public mutating func createGroup(name: String) throws -> UUID {
        let group = SourceGroup(name: try validateGroupName(name))
        groups.append(group)
        return group.id
    }

    public mutating func renameGroup(_ id: UUID, to name: String) throws {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].name = try validateGroupName(name, excluding: id)
    }

    /// Its sources move to the end of the previous group (or the start of the next one if it was first).
    public mutating func deleteGroup(_ id: UUID) throws {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        if groups.count == 1 { throw EditError.lastGroup }
        let moving = groups[i].sources
        if i > 0 { groups[i - 1].sources += moving } else { groups[i + 1].sources = moving + groups[i + 1].sources }
        groups.remove(at: i)
    }

    public mutating func moveGroups(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        groups = Self.moved(groups, fromOffsets: offsets, toOffset: destination)
    }

    public mutating func setCollapsed(_ id: UUID, _ collapsed: Bool) {
        if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].isCollapsed = collapsed }
    }

    // MARK: Sources

    /// Users default to "Accounts" and orgs to "Organizations", falling back to the first and last group.
    func defaultGroupIndex(for source: Source) -> Int {
        let wanted: String
        switch source {
        case .user: wanted = Self.accountsGroupName
        case .org: wanted = Self.organizationsGroupName
        case .repo: wanted = Self.repositoriesGroupName
        }
        if let i = groups.firstIndex(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return i }
        if case .user = source { return 0 }
        return max(0, groups.count - 1)
    }

    public mutating func add(_ source: Source, to groupID: UUID? = nil) throws {
        if contains(source.name) { throw EditError.duplicate(source.name) }
        if groups.isEmpty { groups = [SourceGroup(name: Self.accountsGroupName)] }
        // Repositories get a group of their own the first time one is added without choosing a group.
        if case .repo = source, groupID == nil,
           !groups.contains(where: { $0.name.caseInsensitiveCompare(Self.repositoriesGroupName) == .orderedSame }) {
            groups.append(SourceGroup(name: Self.repositoriesGroupName))
        }
        let i = groupID.flatMap { id in groups.firstIndex { $0.id == id } } ?? defaultGroupIndex(for: source)
        groups[i].sources.append(source)
        dismissed.remove(source.id)
    }

    /// Swaps `old` for `new` in place, keeping its group, position and visibility.
    public mutating func replace(_ old: Source, with new: Source) throws {
        guard let g = groups.firstIndex(where: { $0.sources.contains(old) }),
              let i = groups[g].sources.firstIndex(of: old) else { return }
        if new.name.caseInsensitiveCompare(old.name) != .orderedSame, contains(new.name) {
            throw EditError.duplicate(new.name)
        }
        if hidden.remove(old.id) != nil { hidden.insert(new.id) }
        if forceShown.remove(old.id) != nil { forceShown.insert(new.id) }
        if newlyDiscovered.remove(old.id) != nil { newlyDiscovered.insert(new.id) }
        autoHidden.remove(old.id)
        groups[g].sources[i] = new
    }

    /// Deleting is deliberate, so the sources are remembered and will not come back through discovery.
    public mutating func remove(_ sources: [Source]) {
        for i in groups.indices { groups[i].sources.removeAll { sources.contains($0) } }
        let ids = sources.map(\.id)
        hidden.subtract(ids)
        newlyDiscovered.subtract(ids)
        forceShown.subtract(ids)
        autoHidden.subtract(ids)
        dismissed.formUnion(ids)
    }

    /// Moves sources to `groupID`, before the source at `index` of that group's full list (nil appends).
    public mutating func move(_ sources: [Source], toGroup groupID: UUID, at index: Int? = nil) {
        guard let dest = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let moving = allSources.filter { sources.contains($0) } // keep their current relative order
        guard !moving.isEmpty else { return }
        // Remember the anchor so removing the moved sources first cannot shift the insertion point.
        let anchor = index.flatMap { groups[dest].sources.indices.contains($0) ? groups[dest].sources[$0] : nil }
        if let anchor, moving.contains(anchor) { return } // dropped onto itself (or onto another selected source)
        for i in groups.indices { groups[i].sources.removeAll { moving.contains($0) } }
        let at = anchor.flatMap { groups[dest].sources.firstIndex(of: $0) } ?? groups[dest].sources.count
        groups[dest].sources.insert(contentsOf: moving, at: at)
    }

    /// Reorders what the sidebar shows inside one group; hidden sources keep their slots.
    public mutating func moveVisible(inGroup id: UUID, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        let visible = groups[g].sources.filter { !isHidden($0) }
        let reordered = Self.moved(visible, fromOffsets: offsets, toOffset: destination)
        let slots = groups[g].sources.indices.filter { !isHidden(groups[g].sources[$0]) }
        for (slot, source) in zip(slots, reordered) { groups[g].sources[slot] = source }
    }

    public mutating func removeVisible(inGroup id: UUID, atOffsets offsets: IndexSet) {
        guard let g = groups.firstIndex(where: { $0.id == id }) else { return }
        let visible = groups[g].sources.filter { !isHidden($0) }
        remove(offsets.sorted().compactMap { visible.indices.contains($0) ? visible[$0] : nil })
    }

    /// Same semantics as SwiftUI's `onMove`: `destination` is an index in the pre-move array.
    static func moved<T>(_ array: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        var array = array
        let moving = offsets.sorted().compactMap { array.indices.contains($0) ? array[$0] : nil }
        let before = offsets.filter { $0 < destination }.count
        for i in offsets.sorted(by: >) where array.indices.contains(i) { array.remove(at: i) }
        array.insert(contentsOf: moving, at: max(0, min(array.count, destination - before)))
        return array
    }

    // MARK: Visibility

    /// Acting on a source (showing or hiding it) settles it: it stops being "new", and an explicit show
    /// protects it from the empty-source rule.
    public mutating func setHidden(_ sources: [Source], _ hide: Bool) {
        let known = Set(allSources.map(\.id))
        for s in sources where known.contains(s.id) {
            newlyDiscovered.remove(s.id)
            if hide {
                hidden.insert(s.id); forceShown.remove(s.id)
            } else {
                hidden.remove(s.id); forceShown.insert(s.id); autoHidden.remove(s.id)
            }
        }
    }

    public mutating func setGroupHidden(_ id: UUID, _ hide: Bool) {
        if let g = group(withID: id) { setHidden(g.sources, hide) }
    }

    public mutating func showAll() {
        hidden = []
        forceShown = Set(allSources.map(\.id))
        autoHidden = []
    }

    /// Shows exactly `sources` and hides everything else.
    public mutating func showOnly(_ sources: [Source]) {
        let keep = Set(sources.map(\.id))
        hidden = Set(allSources.map(\.id).filter { !keep.contains($0) })
        forceShown = keep
        autoHidden = []
    }

    // MARK: Discovery

    /// Adds orgs the viewer belongs to that the catalog has never seen (skipping ones the user deleted).
    /// They are flagged new and, by default, hidden, so joining dozens of orgs does not flood the sidebar.
    @discardableResult
    public mutating func discover(orgs: [String]) -> [String] {
        var added: [String] = []
        for name in orgs.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            let source = Source.org(name)
            if contains(name) || dismissed.contains(source.id) { continue }
            guard (try? add(source)) != nil else { continue }
            newlyDiscovered.insert(source.id)
            if settings.newOrgPolicy == .hidden { hidden.insert(source.id) }
            added.append(name)
        }
        return added
    }

    /// "Keep hidden" / "I have seen these": clears the new flag without changing visibility.
    public mutating func markAllSeen() { newlyDiscovered = [] }

    // MARK: Auto-hide

    /// Recomputes which sources the empty-source rule hides. A source is hidden when it has no open PRs, unless
    /// it was explicitly shown, is in `keeping` (what you are looking at), or its counts are missing or failed.
    /// If the rule would hide every remaining source it hides none, so the sidebar never goes blank by itself.
    public mutating func updateAutoHidden(counts: [String: SourceCounts], keeping: Set<String> = []) {
        guard settings.autoHideEmpty else { autoHidden = []; return }
        let candidates = allSources.filter { s in
            guard !hidden.contains(s.id), !forceShown.contains(s.id), !keeping.contains(s.id),
                  let c = counts[s.id], c.error == nil else { return false }
            return c.open == 0
        }.map(\.id)
        let visibleByHand = allSources.filter { !hidden.contains($0.id) }
        autoHidden = candidates.count < visibleByHand.count ? Set(candidates) : []
    }

    // MARK: Sorting

    public enum SortOrder: Sendable { case alphabetical, kindThenAlphabetical }

    /// Sorts one group, or every group when `id` is nil.
    public mutating func sort(_ order: SortOrder = .alphabetical, group id: UUID? = nil) {
        func key(_ s: Source) -> String { s.name.lowercased() }
        func rank(_ s: Source) -> Int { switch s { case .user: 0; case .org: 1; case .repo: 2 } }
        for i in groups.indices where id == nil || groups[i].id == id {
            switch order {
            case .alphabetical: groups[i].sources.sort { key($0) < key($1) }
            case .kindThenAlphabetical: groups[i].sources.sort { (rank($0), key($0)) < (rank($1), key($1)) }
            }
        }
    }

    // MARK: Persistence

    public static let defaultsKey = "sources.v2"

    public static func load(from defaults: UserDefaults = .standard, key: String = defaultsKey) -> SourceCatalog? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SourceCatalog.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard, key: String = defaultsKey) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}
