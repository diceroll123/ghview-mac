import SwiftUI
import GHCore
import UniformTypeIdentifiers

/// What a drag carries: a source or a whole group, identified by id.
struct SourceDrag: Codable, Transferable {
    enum Kind: String, Codable { case source, group }
    var kind: Kind
    var id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct SourceSidebar: View {
    @Environment(AppModel.self) private var model
    /// Extra space above a group header. The list's own row spacing already separates headers from rows, so this
    /// only needs to be a little, or collapsed groups end up with wide empty bands between them.
    static let groupGap: CGFloat = 3
    @Binding var sheet: SourceSheetTarget?

    var body: some View {
        List(selection: selection) {
            InboxBlock(sheet: $sheet)
            ForEach(model.catalog.groups) { group in
                // The header is an ordinary row, not a Section header: AppKit draws a hover chevron on every
                // sidebar section header and offers no way to turn it off, so we draw our own beside the name.
                GroupHeader(group: group, sheet: $sheet)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .padding(.top, group.id == model.catalog.groups.first?.id ? 0 : Self.groupGap)
                do {
                    let visible = group.isCollapsed ? [] : model.catalog.visibleSources(in: group)
                    ForEach(visible) { source in
                        SourceRow(source: source)
                            .tag(source.id)
                            .draggable(SourceDrag(kind: .source, id: source.id))
                            .dropDestination(for: SourceDrag.self) { drops, _ in
                                let ids = drops.filter { $0.kind == .source }.map(\.id)
                                guard !ids.isEmpty else { return false }
                                model.dropSources(ids: ids, onto: source, inGroup: group.id)
                                return true
                            }
                            .contextMenu {
                                Button { model.open(source) } label: { Label("Open on GitHub", systemImage: "safari") }
                                Button { model.open(source, pullRequests: true) } label: {
                                    Label("Open Pull Requests on GitHub", systemImage: "arrow.triangle.pull")
                                }
                                Divider()
                                Button("Edit...") { sheet = .edit(source) }
                                Button("Add Source...") { sheet = .add(group: group.id) }
                                Button("New Group...") { sheet = .newGroup }
                                Button("Hide") { model.setSourcesHidden([source], true) }
                                Menu("Move to") {
                                    ForEach(model.catalog.groups.filter { $0.id != group.id }) { other in
                                        Button(other.name) { model.moveSources([source], toGroup: other.id) }
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) { model.removeSources([source]) }
                            }
                        if model.settings.showRepoTree, source.repoId == nil, model.isExpanded(source) { RepoChildren(source: source) }
                    }
                    if visible.isEmpty && !group.isCollapsed {
                        Text(group.sources.isEmpty ? "Drop sources here" : "All sources hidden")
                            .font(.caption).foregroundStyle(.tertiary)
                            .dropDestination(for: SourceDrag.self) { drops, _ in
                                dropOnHeader(drops, group)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Right-click on empty space between or below the rows.
        .contextMenu {
            Button("Add Source...") { sheet = .add(group: nil) }
            Button("New Group...") { sheet = .newGroup }
        }
    }

    /// The `List` selection is a set of tags: plain source ids (several may be selected together), or
    /// `repo:owner/name` and the other destination kinds. Different kinds never mix: when the user adds one of a
    /// different kind to the selection, that newly chosen one becomes the whole selection.
    private var selection: Binding<Set<String>> {
        Binding(
            get: {
                switch model.destination {
                case .sources(let ids): ids
                case .some(let d): [d.tag]
                case nil: []
                }
            },
            set: { new in
                let current: Set<String> = {
                    switch model.destination {
                    case .sources(let ids): ids
                    case .some(let d): [d.tag]
                    case nil: []
                    }
                }()
                guard new != current else { return }
                let added = new.subtracting(current)
                let others = (added.isEmpty ? new : added).filter { $0.contains(":") }.sorted()
                if let tag = others.first, let d = SidebarDestination.from(tag: tag) { model.destination = d }
                else { model.destination = new.isEmpty ? nil : .sources(new.filter { !$0.contains(":") }) }
            })
    }

    private func dropOnHeader(_ drops: [SourceDrag], _ group: SourceGroup) -> Bool {
        let sources = drops.filter { $0.kind == .source }.map(\.id)
        if !sources.isEmpty { model.dropSources(ids: sources, onto: nil, inGroup: group.id); return true }
        if let dragged = drops.first(where: { $0.kind == .group }).flatMap({ UUID(uuidString: $0.id) }) {
            model.dropGroup(dragged, before: group.id)
            return true
        }
        return false
    }
}

struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        let counts = model.counts[source.id]
        let empty = counts.map { $0.error == nil && $0.open == 0 } ?? false
        HStack(spacing: 8) {
            if model.settings.showRepoTree, source.repoId == nil {
                Button { model.toggleExpanded(source) } label: {
                    Image(systemName: model.isExpanded(source) ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 10)
                }
                .buttonStyle(.plain)
                .help(model.isExpanded(source) ? "Hide repositories" : "Show repositories")
            }
            AvatarView(source: source)
            Text(source.displayName).lineLimit(1).foregroundStyle(empty ? .secondary : .primary)
            if let repo = source.repoId { RepoFlags(repo: model.repoInfo(for: repo)) }
            if model.catalog.isNew(source) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("New organization")
            }
            Spacer(minLength: 4)
            CountBadges(counts: counts)
        }
    }
}

/// The fixed top of the sidebar, like github.com/pulls: the Inbox tree, then the Views group (the built-in
/// searches, then the user's own). Everything in it
/// can be hidden (right-click, or the View menu); a hidden Inbox also stops loading its PRs.
struct InboxBlock: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: SourceSheetTarget?

    var body: some View {
        let layout = model.layout
        if !layout.inboxHidden {
            InboxHeader().selectionDisabled().listRowSeparator(.hidden)
            if layout.inboxExpanded {
                ForEach(layout.visibleSections) { section in
                    let tag = SidebarDestination.inbox(section).tag
                    InboxRow(title: section.title, symbol: section.symbol, count: model.inboxCounts[section] ?? 0,
                             loading: model.inboxLoading && !model.inboxLoaded, tint: Self.tint(section))
                        .tag(tag)
                        .contextMenu { Button("Hide") { model.hideEntry(tag) } }
                }
            }
        }
        if !layout.savedViewsHidden {
            SavedViewsHeader(sheet: $sheet).selectionDisabled().listRowSeparator(.hidden).padding(.top, SourceSidebar.groupGap)
            if layout.savedViewsExpanded {
                ForEach(layout.visibleSearches) { search in
                    let tag = SidebarDestination.search(search).tag
                    InboxRow(title: search.title, symbol: search.symbol, count: model.count(for: search) ?? 0,
                             loading: false, tint: search == .reviewRequests ? Color.accentColor : nil)
                        .tag(tag)
                        .contextMenu {
                            Button("Save as View...") { sheet = .newView(query: search.scope) }
                            Button("Hide") { model.hideEntry(tag) }
                        }
                }
                ForEach(layout.visibleViews) { view in
                    let tag = SidebarDestination.savedView(view.id).tag
                    InboxRow(title: view.name, symbol: "bookmark", count: model.count(for: view) ?? 0, loading: false,
                             tint: nil, problem: model.searchCountErrors[view.scope])
                        .tag(tag)
                        .contextMenu {
                            Button("Edit...") { sheet = .editView(view.id) }
                            Button("Hide") { model.hideEntry(tag) }
                            Divider()
                            Button("Delete", role: .destructive) { model.deleteView(view.id) }
                        }
                }
                if layout.savedViews.isEmpty {
                    Text("Save your own searches with +").font(.caption).foregroundStyle(.tertiary).selectionDisabled()
                        .padding(.leading, 4)
                }
            }
        }
    }

    static func tint(_ section: InboxSection) -> Color? {
        switch section {
        case .needsYourReview, .needsTeamsReview: Color.accentColor
        case .needsAction: .orange
        default: nil
        }
    }
}

struct InboxHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let layout = model.layout
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.layout.inboxExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(layout.inboxExpanded ? 90 : 0)).frame(width: 10)
                    Text("Inbox").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(layout.inboxExpanded ? "Collapse Inbox" : "Expand Inbox")
            Spacer()
            if !layout.inboxExpanded {
                let waiting = (model.inboxCounts[.needsYourReview] ?? 0) + (model.inboxCounts[.needsTeamsReview] ?? 0)
                if waiting > 0 { CountPill(count: waiting, fill: Color.accentColor, text: .white) }
            }
            if layout.hiddenEntryCount > 0 {
                Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary)
                    .help("\(layout.hiddenEntryCount) hidden entries")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Hide Inbox") { model.setInboxHidden(true) }
            if layout.hiddenEntryCount > 0 {
                Divider()
                Button("Show Hidden Entries (\(layout.hiddenEntryCount))") { model.showHiddenEntries() }
            }
        }
    }
}

struct SavedViewsHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: SourceSheetTarget?

    var body: some View {
        let layout = model.layout
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.layout.savedViewsExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(layout.savedViewsExpanded ? 90 : 0)).frame(width: 10)
                    Text("Views").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button { sheet = .newView(query: "") } label: { Image(systemName: "plus").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Save a search as a view")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("New View...") { sheet = .newView(query: "") }
            Button(layout.quickSearchesHidden ? "Show Search Shortcuts" : "Hide Search Shortcuts") {
                model.setQuickSearchesHidden(!layout.quickSearchesHidden)
            }
            Button("Hide Views") { model.setSavedViewsHidden(true) }
            if layout.hiddenEntryCount > 0 {
                Divider()
                Button("Show Hidden Entries (\(layout.hiddenEntryCount))") { model.showHiddenEntries() }
            }
        }
    }
}

/// One inbox section or quick search: icon, title and the number of PRs in it.
struct InboxRow: View {
    let title: String
    let symbol: String
    let count: Int
    let loading: Bool
    var tint: Color?
    var indent = true
    /// Set when GitHub refused the search (a saved view with a malformed query).
    var problem: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(tint ?? .secondary)
            Text(title).lineLimit(1).foregroundStyle(count == 0 && !loading ? .secondary : .primary)
            Spacer(minLength: 4)
            if let problem { Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).help(problem) }
            else if loading { ProgressView().controlSize(.mini) }
            else if count > 0 { CountPill(count: count, fill: tint ?? Color.secondary.opacity(0.2), text: tint == nil ? .secondary : .white) }
        }
        .padding(.leading, indent ? 4 : 0)
        .help(title)
    }
}

struct CountPill: View {
    let count: Int
    let fill: Color
    let text: Color

    var body: some View {
        Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(text)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(fill, in: Capsule())
    }
}

/// A source's repositories, shown under its row when it is expanded. Selecting one opens its PRs.
struct RepoChildren: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        let repos = model.repos(in: source)
        ForEach(repos) { repo in
            SidebarRepoRow(repo: repo).tag(SidebarDestination.repo(repo.id).tag)
        }
        if let message = model.repoFailures[source.name] {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Could not list repositories: \(message)").lineLimit(3)
                Spacer(minLength: 0)
                Button("Retry") { Task { await model.retryFailedRepos() } }.controlSize(.mini)
            }
            .font(.caption).foregroundStyle(.secondary).padding(.leading, 18).selectionDisabled()
        } else if repos.isEmpty {
            Group {
                if model.loadingRepoSources.contains(source.id) { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Loading repositories...") } }
                else { Text("No repositories") }
            }
            .font(.caption).foregroundStyle(.tertiary).padding(.leading, 18).selectionDisabled()
        }
        if model.isTruncated(source) {
            Text("Showing the \(AppModel.maxReposPerSource) most recently pushed repositories.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 18).selectionDisabled()
        }
    }
}

struct SidebarRepoRow: View {
    @Environment(AppModel.self) private var model
    let repo: RepoInfo

    var body: some View {
        HStack(spacing: 6) {
            LanguageIcon(language: repo.language)
            Text(repo.id.name).lineLimit(1)
                .foregroundStyle(repo.isArchived || repo.openPRs == 0 ? .secondary : .primary)
            RepoFlags(repo: repo)
            Spacer(minLength: 4)
            if repo.openPRs > 0 {
                Text("\(repo.openPRs)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.secondary.opacity(0.2), in: Capsule())
            }
        }
        .padding(.leading, 18)
        .contextMenu { RepoContextMenu(repo: repo.id) }
    }
}

/// Small marks beside a repository's name: a lock when it is private, an archive box when it is archived.
struct RepoFlags: View {
    let repo: RepoInfo?
    /// PR lists leave the lock and the fork mark out: they are properties of the repository, not of the PR, and
    /// would only be noise on every row. Archived stays, because it explains why a PR cannot be acted on.
    var showsPrivate = true
    var showsFork = true

    var body: some View {
        if let repo {
            if repo.isPrivate && showsPrivate {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary).help("Private repository")
            }
            if repo.isFork && showsFork {
                Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary).help("Fork")
            }
            if repo.isArchived {
                Image(systemName: "archivebox.fill").font(.caption2).foregroundStyle(.orange)
                    .help("Archived: read-only, so PRs here cannot be changed")
            }
        }
    }
}

/// What can be done with a repository from anywhere it is shown.
struct RepoContextMenu: View {
    @Environment(AppModel.self) private var model
    let repo: RepoId

    var body: some View {
        Button { model.open(repo) } label: { Label("Open on GitHub", systemImage: "safari") }
        Button { model.open(repo, pullRequests: true) } label: { Label("Open Pull Requests on GitHub", systemImage: "arrow.triangle.pull") }
        Divider()
        Button { model.copy(repo.fullName) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
        Button { model.copy(repo.url.absoluteString) } label: { Label("Copy URL", systemImage: "link") }
        Divider()
        Button { model.addRepoSource(repo) } label: { Label("Add to Sources", systemImage: "plus.square") }
            .disabled(model.isSource(repo))
    }
}

/// Open PRs in gray; PRs waiting on the viewer's review in the accent color; a lock or warning if GitHub refused.
struct CountBadges: View {
    let counts: SourceCounts?

    var body: some View {
        if let c = counts {
            if let error = c.error {
                Image(systemName: c.needsSSO ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(c.needsSSO ? "This organization requires SAML SSO, and your gh token is not authorized for it yet.\n\n\(error)" : error)
            } else {
                HStack(spacing: 4) {
                    if c.reviewRequested > 0 {
                        pill(c.reviewRequested, fill: Color.accentColor, text: .white)
                            .help("\(c.reviewRequested) waiting for your review")
                    }
                    if c.open > 0 {
                        pill(c.open, fill: Color.secondary.opacity(0.2), text: .secondary)
                            .help("\(c.open) open pull requests")
                    }
                }
            }
        }
    }

    private func pill(_ n: Int, fill: Color, text: Color) -> some View {
        Text("\(n)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(text)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(fill, in: Capsule())
    }
}

struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let group: SourceGroup
    @Binding var sheet: SourceSheetTarget?

    private var hiddenInGroup: Int { group.sources.filter(model.isSourceHidden).count }

    var body: some View {
        HStack(spacing: 6) {
            // Our own disclosure control, next to the name, so the trailing edge only ever holds badges and "+".
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { model.setGroupCollapsed(group.id, !group.isCollapsed) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                        .frame(width: 10)
                    Text(group.name).font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
            Spacer()
            if group.isCollapsed {
                // a collapsed group still shows whether anything inside needs you
                CountBadges(counts: model.totals(for: model.catalog.visibleSources(in: group)))
                    .help("\(group.sources.count - hiddenInGroup) sources")
            }
            if hiddenInGroup > 0 {
                Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.tertiary)
                    .help("\(hiddenInGroup) hidden in this group")
            }
            Button { sheet = .add(group: group.id) } label: { Image(systemName: "plus").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Add a source to \(group.name)")
        }
        .contentShape(Rectangle())
        .draggable(SourceDrag(kind: .group, id: group.id.uuidString))
        .dropDestination(for: SourceDrag.self) { drops, _ in
            let sources = drops.filter { $0.kind == .source }.map(\.id)
            if !sources.isEmpty { model.dropSources(ids: sources, onto: nil, inGroup: group.id); return true }
            if let dragged = drops.first(where: { $0.kind == .group }).flatMap({ UUID(uuidString: $0.id) }) {
                model.dropGroup(dragged, before: group.id)
                return true
            }
            return false
        }
        .contextMenu {
            Button("Browse All in Group") {
                model.selectedSourceIDs = Set(model.catalog.visibleSources(in: group).map(\.id))
            }
            .disabled(model.catalog.visibleSources(in: group).isEmpty)
            Divider()
            Button("Add Source to \(group.name)...") { sheet = .add(group: group.id) }
            Button("Rename...") { sheet = .renameGroup(group.id) }
            Button("New Group...") { sheet = .newGroup }
            Divider()
            Button("Sort A-Z") { model.sortSources(.alphabetical, group: group.id) }
            Button("Hide All in Group") { model.setGroupHidden(group.id, true) }.disabled(group.sources.count == hiddenInGroup)
            Button("Show All in Group") { model.setGroupHidden(group.id, false) }.disabled(hiddenInGroup == 0)
            Divider()
            Button("Delete Group", role: .destructive) {
                do { try model.deleteGroup(group.id) } catch { model.error = error.localizedDescription }
            }
            .disabled(model.catalog.groups.count < 2)
        }
    }
}

/// Create or rename a group.
struct GroupNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: SourceSheetTarget
    @State private var name = ""
    @State private var message: String?

    private var renamingID: UUID? { if case .renameGroup(let id) = target { id } else { nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(renamingID == nil ? "New Group" : "Rename Group").font(.headline)
            TextField("Group name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(renamingID == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { if let id = renamingID { name = model.catalog.group(withID: id)?.name ?? "" } }
    }

    private func save() {
        do {
            if let id = renamingID { try model.renameGroup(id, to: name) } else { try model.createGroup(name) }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

/// Creates or edits a saved view: a name and a GitHub search, checked against GitHub as you type.
struct SavedViewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: SourceSheetTarget
    @State private var name = ""
    @State private var query = ""
    @State private var message: String?
    @State private var preview: (count: Int?, error: String?)?

    private var editingID: UUID? { if case .editView(let id) = target { id } else { nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingID == nil ? "New Saved View" : "Edit Saved View").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Search, e.g. label:bug org:acme", text: $query).textFieldStyle(.roundedBorder).onSubmit(save)
                Text("GitHub search syntax. Only open pull requests are shown.").font(.caption).foregroundStyle(.tertiary)
            }
            previewLine.frame(height: 18, alignment: .leading)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editingID == nil ? "Create" : "Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            switch target {
            case .editView(let id):
                if let v = model.layout.savedViews.first(where: { $0.id == id }) { name = v.name; query = v.query }
            case .newView(let q): query = q
            default: break
            }
        }
        .task(id: query) {
            preview = nil
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(500)) // wait for a pause in typing
            guard !Task.isCancelled else { return }
            let result = await model.previewCount(for: query)
            if !Task.isCancelled { preview = result }
        }
    }

    @ViewBuilder private var previewLine: some View {
        if let preview {
            if let error = preview.error {
                Label("GitHub could not run this search: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if let count = preview.count {
                Label("\(count.formatted()) open PR\(count == 1 ? "" : "s") match", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking...").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func save() {
        do {
            if let id = editingID { try model.updateView(id, name: name, query: query) }
            else { try model.saveView(name: name, query: query) }
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
