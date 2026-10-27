import SwiftUI

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
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Show each source's repositories as child rows in the sidebar. Off: sources are a flat list.
    var showRepoTree: Bool { didSet { defaults.set(showRepoTree, forKey: Key.showRepoTree) } }

    /// Leave archived repositories out of the repository lists. Off: they are listed and marked as archived.
    var hideArchivedRepos: Bool { didSet { defaults.set(hideArchivedRepos, forKey: Key.hideArchivedRepos) } }

    /// With several PRs selected, right-clicking one of them acts on just that PR (the default) or on all of them.
    var contextMenuScope: ContextMenuScope { didSet { defaults.set(contextMenuScope.rawValue, forKey: Key.contextMenuScope) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showRepoTree = defaults.bool(forKey: Key.showRepoTree)
        hideArchivedRepos = defaults.bool(forKey: Key.hideArchivedRepos)
        contextMenuScope = defaults.string(forKey: Key.contextMenuScope).flatMap(ContextMenuScope.init(rawValue:)) ?? .clickedOnly
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var model = model
        Form {
            Section("Sidebar") {
                Toggle("Show repositories under each source", isOn: $settings.showRepoTree)
                Text("Adds an arrow to every source that lists its repositories beneath it. Off keeps the sidebar a plain list of sources.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show Inbox", isOn: Binding(get: { !model.layout.inboxHidden }, set: { model.setInboxHidden(!$0) }))
                Toggle("Show the built-in searches in Views (Authored by me, Assigned to me, ...)", isOn: Binding(
                    get: { !model.layout.quickSearchesHidden }, set: { model.setQuickSearchesHidden(!$0) }))
                Toggle("Show Views", isOn: Binding(get: { !model.layout.savedViewsHidden }, set: { model.setSavedViewsHidden(!$0) }))
                if model.hiddenSidebarCount > 0 {
                    Button("Show everything that was hidden at the top") { model.showAllSidebarItems() }
                }
            }
            Section("Repositories") {
                Toggle("Hide archived repositories", isOn: $settings.hideArchivedRepos)
                Text("Archived repositories are read-only. When shown they are marked with an archive icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pull request list") {
                Picker("When several PRs are selected, right-click acts on", selection: $settings.contextMenuScope) {
                    Text("Only the PR I right-click").tag(ContextMenuScope.clickedOnly)
                    Text("All selected PRs").tag(ContextMenuScope.allSelected)
                }
                .pickerStyle(.radioGroup)
                Text("Applies to the right-click menu. The buttons below the list always act on the whole selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
