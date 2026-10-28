import SwiftUI
import GHCore

@main
struct GHViewApp: App {
    #if DEBUG
        // Demo mode (debug builds only, see scripts/generate-screenshot.sh) gets its own throwaway defaults and
        // cache file, so running it never touches - or is affected by - a real install's settings.
        private static let isDemo = ProcessInfo.processInfo.environment["GHVIEW_DEMO_FIXTURES"] == "1"
        @State private var model = AppModel(
            defaults: isDemo ? UserDefaults(suiteName: "ghview-demo-\(UUID().uuidString)")! : .standard,
            countsURL: isDemo
                ? FileManager.default.temporaryDirectory.appendingPathComponent("ghview-demo-\(UUID().uuidString).json")
                : SourceCountsCache.defaultURL)
    #else
        @State private var model = AppModel()
    #endif

    var body: some Scene {
        // One window, deliberately: navigation (sources, repo, selection, filters) lives in one shared model, so a
        // second window would show and fight over the same state. A single `Window` also has no New Window command.
        Window("GHView", id: "main") {
            ContentView()
                .environment(model)
                .environment(AvatarStore.shared)
                .frame(minWidth: 1000, minHeight: 600)
                .task {
                    #if DEBUG
                        if Self.isDemo { model.startDemo(); return }
                    #endif
                    await model.start()
                }
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refresh() }.keyboardShortcut("r")
            }
            SelectionCommands(model: model)
            SidebarCommands(model: model)
            CallLogCommands()
        }
        Window("Request Log", id: "log") {
            CallLogView().environment(model)
        }
        .defaultSize(width: 900, height: 480)
        Settings {
            SettingsView().environment(model).environment(AvatarStore.shared)
        }
    }
}

/// What the PR list offers to menu commands while it has keyboard focus.
struct PRListCommands {
    var selectAll: () -> Void
}

extension FocusedValues {
    @Entry var prList: PRListCommands?
}

/// Select All belongs to whatever has focus: the PR list selects its visible PRs, anything else (a comment box,
/// the filter, a source name) gets the ordinary text command. Clearing the PR selection is a separate command.
struct SelectionCommands: Commands {
    let model: AppModel
    @FocusedValue(\.prList) private var prList

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button("Select All") {
                if let prList { prList.selectAll() } else { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
            .keyboardShortcut("a")
            Button("Clear PR Selection") { model.selection.clear() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.selection.isSelectionMode)
        }
    }
}

/// View menu toggles for the sidebar's top blocks, so a hidden Inbox can always be brought back.
struct SidebarCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Show Inbox", isOn: Binding(get: { !model.layout.inboxHidden }, set: { model.setInboxHidden(!$0) }))
            Toggle(
                "Show Search Shortcuts",
                isOn: Binding(get: { !model.layout.quickSearchesHidden }, set: { model.setQuickSearchesHidden(!$0) }))
            Toggle("Show Views", isOn: Binding(get: { !model.layout.savedViewsHidden }, set: { model.setSavedViewsHidden(!$0) }))
            Button("Show Hidden Inbox Entries") { model.showHiddenEntries() }
                .disabled(model.layout.hiddenEntryCount == 0)
        }
    }
}
