import SwiftUI
import GHCore

/// What a right-click menu acts on when several PRs are selected and the click lands on one of them.
enum ContextMenuScope: String, CaseIterable, Identifiable {
    case clickedOnly, allSelected
    var id: String { rawValue }
}

/// Preferences, stored in `UserDefaults` and edited in the Settings window (Cmd-comma).
@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let showRepoTree = "settings.showRepoTree"
        static let hideArchivedRepos = "settings.hideArchivedRepos"
        static let contextMenuScope = "settings.contextMenuScope"
        static let repoSubtitleEntries = "settings.repoSubtitleEntries"
        static let sourceBadgeEntries = "settings.sourceBadgeEntries"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Show each source's repositories as child rows in the sidebar. Off: sources are a flat list.
    var showRepoTree: Bool { didSet { defaults.set(showRepoTree, forKey: Key.showRepoTree) } }

    /// Leave archived repositories out of the repository lists. Off: they are listed and marked as archived.
    var hideArchivedRepos: Bool { didSet { defaults.set(hideArchivedRepos, forKey: Key.hideArchivedRepos) } }

    /// With several PRs selected, right-clicking one of them acts on just that PR (the default) or on all of them.
    var contextMenuScope: ContextMenuScope { didSet { defaults.set(contextMenuScope.rawValue, forKey: Key.contextMenuScope) } }

    /// What to show under a repository's name, and in what order.
    var repoSubtitleEntries: [BadgeEntry<RepoSubtitleItem>] {
        didSet { Self.save(repoSubtitleEntries, forKey: Key.repoSubtitleEntries, to: defaults) }
    }

    /// What to show as trailing badges on a sidebar source or group row, and in what order.
    var sourceBadgeEntries: [BadgeEntry<SourceBadgeItem>] {
        didSet { Self.save(sourceBadgeEntries, forKey: Key.sourceBadgeEntries, to: defaults) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showRepoTree = defaults.bool(forKey: Key.showRepoTree)
        hideArchivedRepos = defaults.bool(forKey: Key.hideArchivedRepos)
        contextMenuScope = defaults.string(forKey: Key.contextMenuScope).flatMap(ContextMenuScope.init(rawValue:)) ?? .clickedOnly
        repoSubtitleEntries = Self.load(forKey: Key.repoSubtitleEntries, from: defaults) ?? RepoSubtitleItem.defaultEntries
        sourceBadgeEntries = Self.load(forKey: Key.sourceBadgeEntries, from: defaults) ?? SourceBadgeItem.defaultEntries
    }

    private static func save<T: Codable>(_ value: T, forKey key: String, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Codable>(forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Which tab of `SettingsView` is showing. Lets other views (the sidebar footer's "Manage Sources", the
/// "No sources" placeholder, ...) open Settings directly to the tab they mean, instead of a separate window.
enum SettingsTab: Hashable {
    case sidebar, repositories, pullRequests, sources
}

/// A toolbar-tabbed window, like System Settings and most native Mac apps' preferences, instead of one long
/// form - and the one place everything settings-shaped lives, including what used to be its own "Manage
/// Sources" sheet.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SettingsTab = .sidebar

    var body: some View {
        TabView(selection: $selection) {
            Tab("Sidebar", systemImage: "sidebar.left", value: SettingsTab.sidebar) { SidebarSettingsTab() }
            Tab("Repositories", systemImage: "folder", value: SettingsTab.repositories) { RepositorySettingsTab() }
            Tab("Pull Requests", systemImage: "arrow.triangle.pull", value: SettingsTab.pullRequests) { PullRequestSettingsTab() }
            Tab("Sources", systemImage: "person.2", value: SettingsTab.sources) { SourcesSettingsTab() }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .scenePadding()
        // Set right before opening Settings (e.g. from "Manage Sources..."), so this window lands on the
        // tab that was actually meant, rather than always reopening on Sidebar. Both triggers are needed:
        // onAppear for the window's first-ever creation, onChange for later opens, since macOS keeps the
        // Settings window (and this view) alive between closes rather than recreating it each time.
        .onAppear {
            if let tab = model.pendingSettingsTab { selection = tab; model.pendingSettingsTab = nil }
        }
        .onChange(of: model.pendingSettingsTab) {
            if let tab = model.pendingSettingsTab { selection = tab; model.pendingSettingsTab = nil }
        }
    }
}

private struct SidebarSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var model = model
        Form {
            Toggle("Show repositories under each source", isOn: $settings.showRepoTree)
            Text("Adds an arrow to every source that lists its repositories beneath it. Off keeps the sidebar a plain list of sources.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Show Inbox", isOn: Binding(get: { !model.layout.inboxHidden }, set: { model.setInboxHidden(!$0) }))
            Toggle("Show Views", isOn: Binding(get: { !model.layout.savedViewsHidden }, set: { model.setSavedViewsHidden(!$0) }))
            Toggle("Show the built-in searches (Authored by me, Assigned to me, ...)", isOn: Binding(
                get: { !model.layout.quickSearchesHidden }, set: { model.setQuickSearchesHidden(!$0) }))
                .padding(.leading, 20)
                .disabled(model.layout.savedViewsHidden)
            if model.hiddenSidebarCount > 0 {
                Button("Show everything that was hidden at the top") { model.showAllSidebarItems() }
            }
            Section("Next to each source") {
                SourceBadgePreview()
                BadgeOrderEditor(entries: $settings.sourceBadgeEntries, showsColor: true,
                    colorable: { $0 == .reviewRequested },
                    hint: { $0 == .repoCount ? "Organizations and users only" : nil }
                ) { $0.label }
                Text("Drag to reorder. Unchecked items are left out entirely. \"Plain\" is a bare number with no badge.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RepositorySettingsTab: View {
    @Environment(AppModel.self) private var model

    /// The orderable text items only - the lock icon's position in this list never affected
    /// anything (it's always drawn as a fixed trailing mark by `RepoFlags`), so it isn't one of them.
    private var orderableEntries: Binding<[BadgeEntry<RepoSubtitleItem>]> {
        Binding(
            get: { model.settings.repoSubtitleEntries.filter { $0.item != .lockIcon } },
            set: { newValue in
                let lock = model.settings.repoSubtitleEntries.first { $0.item == .lockIcon }
                model.settings.repoSubtitleEntries = newValue + (lock.map { [$0] } ?? [])
            }
        )
    }

    private var lockIconEnabled: Binding<Bool> {
        Binding(
            get: { model.settings.repoSubtitleEntries.first { $0.item == .lockIcon }?.enabled ?? true },
            set: { newValue in
                guard let i = model.settings.repoSubtitleEntries.firstIndex(where: { $0.item == .lockIcon }) else { return }
                model.settings.repoSubtitleEntries[i].enabled = newValue
            }
        )
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Hide archived repositories", isOn: $settings.hideArchivedRepos)
            Text("Archived repositories are read-only. When shown they are marked with an archive icon.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Under each repository's name, in the repository list") {
                RepoSubtitlePreview(entries: settings.repoSubtitleEntries)
                BadgeOrderEditor(entries: orderableEntries) { $0.label }
                Toggle("Lock icon for private repositories", isOn: lockIconEnabled)
                Text("Shown when browsing a source's repositories, not in the sidebar. Drag to reorder; unchecked items are left out entirely.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PullRequestSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("When several PRs are selected, right-click acts on", selection: $settings.contextMenuScope) {
                Text("Only the PR I right-click").tag(ContextMenuScope.clickedOnly)
                Text("All selected PRs").tag(ContextMenuScope.allSelected)
            }
            .pickerStyle(.radioGroup)
            Text("Applies to the right-click menu. The buttons below the list always act on the whole selection.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// Show or hide sources without deleting them. Bulk buttons act on whatever the search matches, so with
/// dozens of orgs you can search "acme" and keep only those. Used to be its own "Manage Sources" sheet.
private struct SourcesSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    private var matches: [Source] {
        query.isEmpty ? model.allSources : model.allSources.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var scope: String { query.isEmpty ? "all" : "\(matches.count) matching" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.allSources.count - model.hiddenCount) of \(model.allSources.count) shown")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if model.newOrgCount > 0 {
                HStack {
                    Label("\(model.newOrgCount) new organization\(model.newOrgCount == 1 ? "" : "s") found", systemImage: "sparkles")
                    Spacer()
                    Button("Show them") { model.showNewSources() }
                    Button("Keep as is") { model.markNewSourcesSeen() }
                }
                .font(.callout).controlSize(.small)
                .padding(8).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Hide sources with no open PRs", isOn: Binding(get: { model.catalog.settings.autoHideEmpty },
                                                                       set: { model.setAutoHideEmpty($0) }))
                    .help("Hides sources that have nothing open. Anything you show by hand, and the source you are viewing, stays visible.")
                Picker("New organizations start", selection: Binding(get: { model.catalog.settings.newOrgPolicy },
                                                                      set: { model.setNewOrgPolicy($0) })) {
                    Text("Hidden").tag(SourceSettings.NewOrgPolicy.hidden)
                    Text("Visible").tag(SourceSettings.NewOrgPolicy.visible)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            .font(.callout)
            TextField("Search sources", text: $query).textFieldStyle(.roundedBorder)
            List {
                ForEach(model.catalog.groups) { group in
                    let rows = group.sources.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                    if !rows.isEmpty || query.isEmpty {
                        Section {
                            ForEach(rows) { source in
                                HStack {
                                    Toggle(isOn: Binding(get: { !model.isSourceHidden(source) },
                                                         set: { model.setSourcesHidden([source], !$0) })) {
                                        HStack(spacing: 8) {
                                            AvatarView(source: source, size: 16)
                                            Text(source.displayName)
                                                .foregroundStyle(model.catalog.isAutoHidden(source) ? .secondary : .primary)
                                            if model.catalog.isNew(source) {
                                                Text("NEW").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(Color.accentColor, in: Capsule())
                                            }
                                            if model.catalog.isAutoHidden(source) {
                                                Text("no open PRs").font(.caption).foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    Spacer()
                                    CountBadges(counts: model.counts[source.id], repoCount: source.repoId == nil ? model.repos(in: source).count : nil)
                                    Menu("Move to") {
                                        ForEach(model.catalog.groups.filter { $0.id != group.id }) { other in
                                            Button(other.name) { model.moveSources([source], toGroup: other.id) }
                                        }
                                    }
                                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                                    .disabled(model.catalog.groups.count < 2)
                                }
                            }
                            if rows.isEmpty { Text("No sources").font(.caption).foregroundStyle(.tertiary) }
                        } header: {
                            HStack {
                                Text(group.name)
                                Spacer()
                                Button("Show all") { model.setGroupHidden(group.id, false) }.buttonStyle(.link)
                                Button("Hide all") { model.setGroupHidden(group.id, true) }.buttonStyle(.link)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .frame(minHeight: 280)
            .overlay { if matches.isEmpty && !query.isEmpty { Text("No matching sources").foregroundStyle(.secondary) } }
            FlowLayout(spacing: 6) {
                Button("Show \(scope)") { model.setSourcesHidden(matches, false) }
                Button("Hide \(scope)") { model.setSourcesHidden(matches, true) }
                Button("Show only \(scope)") { model.showOnlySources(matches) }
                Button("Hide all organizations") { model.hideAllOrganizations() }
            }
            .controlSize(.small)
            Text("Hidden sources are kept and can be shown again at any time.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
