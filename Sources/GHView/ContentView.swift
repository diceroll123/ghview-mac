import SwiftUI
import GHCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var sourceSheet: SourceSheetTarget?

    var body: some View {
        NavigationSplitView {
            SourceSidebar(sheet: $sourceSheet)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 380)
            .sheet(item: $sourceSheet) { target in
                switch target {
                case .manage: SourcesManagerSheet()
                case .newGroup, .renameGroup: GroupNameSheet(target: target)
                case .add, .edit: SourceEditSheet(target: target)
                case .newView, .editView: SavedViewSheet(target: target)
                }
            }
            .overlay {
                if model.isStarting { ProgressView("Connecting to GitHub...") }
                else if model.sources.isEmpty {
                    ContentUnavailableView {
                        Label(model.allSources.isEmpty ? "No sources" : "All sources hidden", systemImage: "eye.slash")
                    } actions: {
                        Button("Manage Sources...") { sourceSheet = .manage }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { SidebarFooter { sourceSheet = $0 } }
            .navigationTitle("Sources")
        } content: {
            // Every destination (an inbox section, a search, a source, a repository) opens the same flat PR list.
            Group {
                if model.showsRepoPane {
                    // The repository list stays on the left while one of its repositories' PRs show on the right.
                    ResizableSplit {
                        RepoBrowserView()
                    } trailing: {
                        if case .repo = model.destination { PRListView() }
                        else { ContentUnavailableView("Select a repository", systemImage: "book.closed") }
                    }
                } else { PRListView() }
            }
                // The segment is an inset of the list rather than a row above it, so the list keeps its full height.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.showsSourceSegment {
                        Picker("View", selection: Binding(get: { model.isBrowsingRepos ? SourceView.repos : .prs },
                                                          set: { model.setBrowsingRepos($0 == .repos) })) {
                            ForEach(SourceView.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .solidBarBackground()
                    }
                }
                .overlay {
                    if case .problem(let problem) = model.connection {
                        ConnectionProblemView(problem: problem).background(.background)
                    } else if model.destination == nil, !model.isStarting {
                        ContentUnavailableView("Select something in the sidebar", systemImage: "sidebar.left")
                    }
                }
                .navigationTitle(model.sourceTitle)
                // With the repository list open the column holds two panes (200 + 320 wide at least), so it cannot shrink as far.
                .navigationSplitViewColumnWidth(min: model.showsRepoPane ? 540 : 240, ideal: 635, max: 1000)
                .background(ContentColumnWidth(prsMode: true))
                .onChange(of: model.destination) { _, _ in model.loadPRs() }
        } detail: {
            PRDetailView()
        }
        .confirmationDialog(model.pendingConfirmation?.title ?? "", isPresented: Binding(
            get: { model.pendingConfirmation != nil }, set: { if !$0 { model.pendingConfirmation = nil } }
        ), titleVisibility: .visible) {
            Button(model.pendingConfirmation?.action == .close ? "Close" : "Merge", role: .destructive) { model.confirmPending() }
            Button("Cancel", role: .cancel) { model.pendingConfirmation = nil }
        } message: { Text(model.pendingConfirmation?.message ?? "") }
        .background(TransparentTitleBar())
        .alert("Error", isPresented: .constant(model.error != nil)) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

/// Window chrome the SwiftUI scene cannot express: a title bar with no backing and no separator line, so the sidebar
/// divider is the only edge across the top of the window. The title bar itself stays, so dragging by it is native.
struct TransparentTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

extension View {
    /// An opaque background for the strips at the top and bottom of the list column (the Repos | PRs segment, the
    /// filter header, the status bar), with a hairline. It is not a material: a translucent bar let the list show
    /// through as it scrolled underneath, which made the header hard to read.
    func solidBarBackground(dividerAt edge: Alignment = .bottom) -> some View {
        background(Color(nsColor: .windowBackgroundColor))
            // Not a Divider: a Divider takes the direction of the stack it sits in, even through an overlay, and inside
            // the repository split's HStack it drew a vertical line through the middle of the filter box.
            .overlay(alignment: edge) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
    }
}

/// The two views of a selected source: its repositories, or its PRs.
enum SourceView: String, CaseIterable, Identifiable {
    case repos = "Repos", prs = "PRs"
    var id: String { rawValue }
}

/// Two panes side by side with a draggable divider. Plain SwiftUI rather than `HSplitView`: that one is an AppKit
/// split view, which ignores the safe area insets of the strips above it and ran its panes under them.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    @AppStorage("repoPaneWidth") private var width: Double = 260
    @State private var startWidth: Double?
    let minWidth: Double = 200, maxWidth: Double = 420
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading().frame(width: min(max(width, minWidth), maxWidth)).frame(maxHeight: .infinity)
            Divider()
                .overlay {
                    // A wider invisible grab area than the one-point line.
                    Color.clear.frame(width: 9).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let base = startWidth ?? width
                                startWidth = base
                                width = min(max(base + drag.translation.width, minWidth), maxWidth)
                            }
                            .onEnded { _ in startWidth = nil })
                }
            trailing().frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The repositories of the selected sources, as a list that stays beside the PRs of whichever one is chosen.
struct RepoBrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let repos = model.browsedRepos
        let combined = model.paneSources.count > 1
        List(repos, selection: Binding(get: { model.selectedRepo }, set: { if let r = $0 { model.openRepo(r) } })) { repo in
            HStack(spacing: 8) {
                LanguageIcon(language: repo.language)
                VStack(alignment: .leading, spacing: 1) {
                    Text(combined ? repo.id.fullName : repo.id.name).lineLimit(1)
                    if let lang = repo.language { Text(lang).font(.caption).foregroundStyle(.secondary) }
                }
                RepoFlags(repo: repo)
                Spacer(minLength: 4)
                if repo.openPRs > 0 {
                    Text("\(repo.openPRs)").font(.caption).monospacedDigit()
                        .padding(.horizontal, 6).background(.quaternary, in: Capsule())
                }
            }
            .foregroundStyle(repo.isArchived ? .secondary : .primary)
            .tag(repo.id)
            .contextMenu { RepoContextMenu(repo: repo.id) }
        }
        .listStyle(.inset)
        .safeAreaInset(edge: .top, spacing: 0) {
            let failed = model.paneSources.compactMap { s in model.repoFailures[s.name].map { (s.name, $0) } }
            if !failed.isEmpty {
                SourceFailureNotice(failures: failed) { Task { await model.retryFailedRepos() } }.solidBarBackground()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.paneSources.contains(where: model.isTruncated) {
                Text("Showing the \(AppModel.maxReposPerSource) most recently pushed repositories per source.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading).solidBarBackground(dividerAt: .top)
            }
        }
        .overlay {
            if repos.isEmpty {
                if model.reposLoading { ProgressView("Loading repositories...") }
                else { ContentUnavailableView("No repositories", systemImage: "tray") }
            }
        }
    }
}

/// Shown instead of the lists when GitHub cannot be reached, with what to do about it and a way to try again.
struct ConnectionProblemView: View {
    @Environment(AppModel.self) private var model
    let problem: ConnectionProblem

    var body: some View {
        ContentUnavailableView {
            Label(problem.title, systemImage: problem == .offline ? "wifi.slash" : "exclamationmark.triangle")
        } description: {
            Text(problem.advice).textSelection(.enabled)
        } actions: {
            Button("Retry") { Task { await model.start() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// What the add-source dialog shows once a name resolves: who it is, how big, and what is waiting there.
struct SourceProfileDetails: View {
    let profile: SourceProfile
    let isDuplicate: Bool

    private var kind: String {
        switch profile.source { case .user: "User"; case .org: "Organization"; case .repo: "Repository" }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private func line(_ text: String, _ symbol: String) -> some View {
        Label { Text(text).lineLimit(1) } icon: { Image(systemName: symbol).frame(width: 14) }
            .font(.callout).foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName ?? profile.source.name).font(.title3).fontWeight(.semibold).lineLimit(1)
                HStack(spacing: 6) {
                    // The login is only repeated when the display name is something else.
                    if profile.displayName != nil { Text(profile.source.name).foregroundStyle(.secondary) }
                    Text(kind).foregroundStyle(.tertiary)
                    if isDuplicate { Text("Already in your list").foregroundStyle(.orange) }
                }
                .font(.callout).lineLimit(1)
            }

            HStack(spacing: 6) {
                if profile.isPrivate == true { chip("Private", "lock.fill") }
                if profile.isArchived == true { chip("Archived", "archivebox.fill") }
                if profile.isFork == true { chip("Fork", "arrow.triangle.branch") }
                if let l = profile.language { chip(l, "chevron.left.forwardslash.chevron.right") }
                if let n = profile.stars { chip("\(n.formatted())", "star") }
                if let n = profile.publicRepos { chip("\(n.formatted()) repos", "book.closed") }
                if let n = profile.followers { chip("\(n.formatted()) followers", "person.2") }
                if let d = profile.createdAt {
                    chip("Since \(Calendar.current.component(.year, from: d).formatted(.number.grouping(.never)))", "calendar")
                }
            }

            if let bio = profile.bio { Text(bio).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true) }

            if profile.company != nil || profile.location != nil || profile.website != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let company = profile.company { line(company, "building.2") }
                    if let location = profile.location { line(location, "mappin.and.ellipse") }
                    if let website = profile.website { line(website, "link") }
                }
            }

            Divider()
            activity
        }
    }

    /// What is waiting in the source, or why that cannot be shown.
    @ViewBuilder private var activity: some View {
        if let problem = profile.accessProblem {
            Label(profile.needsSSO ? "Needs SAML SSO authorization for your login. PRs here will not load until it is granted."
                                   : "PRs here cannot be read: \(problem)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if let open = profile.openPRs {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(open > 0 ? Color.accentColor : .secondary)
                Text("\(open.formatted()) open PR\(open == 1 ? "" : "s")").fontWeight(.medium)
                if let asks = profile.reviewRequested, asks > 0 {
                    Text("\(asks.formatted()) waiting for your review").foregroundStyle(Color.accentColor)
                }
            }
            .font(.callout)
        }
        switch profile.membership {
        case .member: line("You are a member", "checkmark.circle")
        case .pending: line("Your membership is pending", "clock")
        case .notMember: line("Not a member, so private repos stay hidden", "lock")
        case .notApplicable, .unknown: EmptyView()
        }
    }
}

/// Colorless language mark: a short monospaced code in a rounded square. Repos without a language get a neutral
/// glyph in the same footprint so names stay aligned.
struct LanguageIcon: View {
    let language: String?

    var body: some View {
        Group {
            if let language {
                if let glyph = LanguageBadge.glyph(for: language), let image = LanguageGlyphCache.image(for: glyph) {
                    // template rendering follows the foreground style, so the logos stay colorless
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 13, height: 13)
                } else {
                    Text(LanguageBadge.code(for: language))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.7).lineLimit(1)
                }
            } else {
                Image(systemName: "folder").font(.system(size: 11))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 26, height: 22)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .help(language ?? "No language detected")
        .accessibilityLabel(language ?? "No language")
    }
}

enum SourceSheetTarget: Identifiable {
    /// Adding, optionally straight into a group (the "+" on a group header).
    case add(group: UUID?)
    case edit(Source)
    case manage
    case newGroup
    case renameGroup(UUID)
    /// A new saved view, optionally starting from a query ("Save as View..." on a shortcut).
    case newView(query: String)
    case editView(UUID)
    var id: String {
        switch self {
        case .add(let g): "add-\(g?.uuidString ?? "any")"
        case .edit(let s): "edit-\(s.id)"
        case .manage: "manage"
        case .newGroup: "new-group"
        case .renameGroup(let g): "rename-\(g)"
        case .newView(let q): "new-view-\(q)"
        case .editView(let v): "edit-view-\(v)"
        }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    let onSheet: (SourceSheetTarget) -> Void
    @State private var showUsage = false

    /// Quiet until it matters: orange under 20% left, red under 5%.
    private func usageColor(_ rl: RateLimit) -> Color {
        let left = rl.limit > 0 ? Double(rl.remaining) / Double(rl.limit) : 1
        return left < 0.05 ? .red : (left < 0.2 ? .orange : .secondary)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let account = model.account {
                Text("@\(account.login)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("Signed in to GitHub through gh as @\(account.login)")
            }
            if let rl = model.rateLimit {
                Button { showUsage.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        Text("API \(rl.remaining.formatted())/\(rl.limit.formatted())").monospacedDigit()
                    }
                    .foregroundStyle(usageColor(rl))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show API usage details")
                .popover(isPresented: $showUsage, arrowEdge: .top) { RateLimitDetail() }
            }
            Spacer()
            if model.newOrgCount > 0 {
                Button { onSheet(.manage) } label: {
                    Label("\(model.newOrgCount) new", systemImage: "sparkles").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("\(model.newOrgCount) organizations were found since last time. Click to review them.")
            }
            if model.hiddenCount + model.hiddenSidebarCount > 0 {
                Button { onSheet(.manage) } label: {
                    Label("\(model.hiddenCount + model.hiddenSidebarCount)", systemImage: "eye.slash")
                }
                .buttonStyle(.plain)
                .help("\(model.hiddenCount) hidden sources and \(model.hiddenSidebarCount) hidden Inbox, shortcut or saved view items. Click to show them again.")
            }
            Menu {
                Button("New Group...") { onSheet(.newGroup) }
                Button("Manage Sources...") { onSheet(.manage) }
                if !model.missingOrgs.isEmpty {
                    Button("Add My Organizations (\(model.missingOrgs.count))") { model.addMissingOrgs() }
                }
                Divider()
                Toggle("Show Inbox", isOn: Binding(get: { !model.layout.inboxHidden }, set: { model.setInboxHidden(!$0) }))
                Toggle("Show Search Shortcuts", isOn: Binding(get: { !model.layout.quickSearchesHidden }, set: { model.setQuickSearchesHidden(!$0) }))
                Toggle("Show Views", isOn: Binding(get: { !model.layout.savedViewsHidden }, set: { model.setSavedViewsHidden(!$0) }))
                Button("Show Everything at the Top") { model.showAllSidebarItems() }.disabled(model.hiddenSidebarCount == 0)
                Divider()
                Button("Hide All Organizations") { model.hideAllOrganizations() }
                Button("Show All Sources") { model.showAllSources() }.disabled(model.hiddenCount == 0)
                Divider()
                Button("Sort A-Z") { model.sortSources(.alphabetical) }
                Button("Sort Users First") { model.sortSources(.kindThenAlphabetical) }
                Divider()
                Button("Reset to Defaults", role: .destructive) { model.resetSources() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Arrange and manage sources")
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct SourceEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: SourceSheetTarget
    @State private var name = ""
    @State private var groupChoice: UUID?
    @State private var busy = false
    @State private var message: String?
    @State private var preview: Preview = .idle
    /// Lookups already done in this dialog, so retyping a name does not hit GitHub again.
    @State private var lookups: [String: SourceProfile] = [:]

    enum Preview: Equatable {
        case idle, checking, found(SourceProfile), notFound(String), failed(String)
    }

    private var isEdit: Bool { if case .edit = target { true } else { false } }
    private var editing: Source? { if case .edit(let s) = target { s } else { nil } }
    private var targetGroupName: String? {
        guard case .add(let id?) = target else { return nil }
        return model.catalog.group(withID: id)?.name
    }

    private var foundSource: Source? { if case .found(let p) = preview { p.source } else { nil } }

    /// Already listed under that name (renaming a source to its own name is fine).
    private var isDuplicate: Bool {
        guard let found = foundSource, model.catalog.contains(found.name) else { return false }
        return editing.map { $0.name.caseInsensitiveCompare(found.name) != .orderedSame } ?? true
    }

    private var notFound: Bool { if case .notFound = preview { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isEdit ? "Edit Source" : (targetGroupName.map { "Add Source to \($0)" } ?? "Add Source")).font(.headline)
            TextField("GitHub username, organization or owner/repo", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            previewRow
            if !isEdit {
                Picker("Group", selection: $groupChoice) {
                    Text("Automatic").tag(UUID?.none)
                    ForEach(model.catalog.groups) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || isDuplicate || notFound)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if case .edit(let s) = target { name = s.name }
            if case .add(let g) = target { groupChoice = g }
        }
        .task(id: name) { await refreshPreview() }
    }

    // MARK: Live preview

    /// Fixed height so the dialog does not jump as the lookup progresses.
    private var previewRow: some View {
        HStack(alignment: .top, spacing: 12) {
            switch preview {
            case .found(let profile): AvatarView(source: profile.source, size: 56)
            case .notFound: AvatarPlaceholder(symbol: "questionmark")
            default: AvatarPlaceholder()
            }
            VStack(alignment: .leading, spacing: 3) {
                switch preview {
                case .idle:
                    Text("Type a username, organization or owner/repo").foregroundStyle(.secondary)
                    Text("A user, organization or single repository is detected automatically.").font(.caption).foregroundStyle(.tertiary)
                case .checking:
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking up...").foregroundStyle(.secondary) }
                case .found(let profile):
                    SourceProfileDetails(profile: profile, isDuplicate: isDuplicate)
                case .notFound(let n):
                    Text("Not found").fontWeight(.semibold)
                    Text("No GitHub user or organization named \(n)").font(.caption).foregroundStyle(.red)
                case .failed(let why):
                    Text("Could not check this name").foregroundStyle(.secondary)
                    Text(why).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 150, alignment: .top)
    }

    private func refreshPreview() async {
        guard let valid = try? SourceCatalog.validate(name) else { preview = .idle; return }
        if let cached = lookups[valid.lowercased()] { preview = .found(cached); return }
        if let editing, editing.name == valid {
            preview = .found(SourceProfile(source: editing))                          // unchanged while editing: show it now,
        } else {                                                                      // fill in the details below
            preview = .idle
            try? await Task.sleep(for: .milliseconds(500))                            // wait for a pause in typing
            guard !Task.isCancelled else { return }
            preview = .checking
        }
        do {
            let profile = try await model.lookupSource(valid)
            guard !Task.isCancelled else { return }
            lookups[valid.lowercased()] = profile
            preview = .found(profile)
        } catch let error as SourceCatalog.EditError {
            if !Task.isCancelled { preview = error == .notFound(valid) ? .notFound(valid) : .idle }
        } catch {
            if !Task.isCancelled { preview = .failed(error.localizedDescription) }
        }
    }

    private func save() {
        guard !busy else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                switch target {
                case .add: try await model.addSource(name, group: groupChoice, resolved: foundSource)
                case .edit(let old): try await model.updateSource(old, to: name, resolved: foundSource)
                case .manage, .newGroup, .renameGroup, .newView, .editView: break // handled by their own sheets
                }
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

// MARK: API usage detail

struct RateLimitDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("GitHub API usage").font(.headline)
                Spacer()
                Button { Task { await model.loadRateBuckets() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh (does not use your quota)")
            }
            if let rl = model.rateLimit { graphQL(rl) }
            let others = model.rateBuckets.filter { $0.name != "graphql" } // GraphQL's own numbers are authoritative
            if !others.isEmpty {
                Divider()
                Text("Other limits").font(.subheadline).foregroundStyle(.secondary)
                ForEach(others) { bucket in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(bucket.title)
                            Spacer()
                            Text("\(bucket.remaining.formatted()) / \(bucket.limit.formatted())").monospacedDigit()
                        }
                        ProgressView(value: bucket.fractionUsed).tint(tint(bucket.fractionUsed))
                        HStack(spacing: 4) { Text("resets in"); Text(bucket.resetAt, style: .relative) }
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            session
            Text("Viewing this panel does not use your quota.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 380)
        .task { await model.loadRateBuckets() }
    }

    private func tint(_ fractionUsed: Double) -> Color {
        fractionUsed > 0.95 ? .red : (fractionUsed > 0.8 ? .orange : .accentColor)
    }

    private func graphQL(_ rl: RateLimit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("GraphQL (what ghview uses)")
                Spacer()
                Text("\(rl.remaining.formatted()) / \(rl.limit.formatted()) left").monospacedDigit()
            }
            ProgressView(value: rl.fractionUsed).tint(tint(rl.fractionUsed))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow { Text("Used this window").foregroundStyle(.secondary); Text((rl.used ?? (rl.limit - rl.remaining)).formatted()) }
                if let reset = rl.resetDate {
                    GridRow {
                        Text("Resets").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(reset, format: .dateTime.hour().minute())
                            Text("(in").foregroundStyle(.secondary); Text(reset, style: .relative).foregroundStyle(.secondary)
                            Text(")").foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Last query").foregroundStyle(.secondary)
                    Text("cost \(rl.cost)" + (rl.nodeCount.map { " (up to \($0.formatted()) nodes)" } ?? ""))
                }
            }
            .font(.callout).monospacedDigit()
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("This session").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.requestLog.count) requests, \(model.requestLog.totalCost) points").font(.caption).monospacedDigit()
            }
            if model.requestLog.entries.isEmpty {
                Text("No requests yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.requestLog.entries.prefix(8)) { e in
                HStack(spacing: 8) {
                    Text(e.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                    Text(e.label).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("-\(e.cost)").foregroundStyle(e.cost > 1 ? .orange : .secondary)
                }
                .font(.caption).monospacedDigit()
            }
        }
    }
}

/// Show or hide sources without deleting them. Bulk buttons act on whatever the search matches, so with dozens
/// of orgs you can search "acme" and keep only those.
struct SourcesManagerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [Source] {
        query.isEmpty ? model.allSources : model.allSources.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var scope: String { query.isEmpty ? "all" : "\(matches.count) matching" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Manage Sources").font(.headline)
                Spacer()
                Text("\(model.allSources.count - model.hiddenCount) of \(model.allSources.count) shown")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
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
                Toggle("Show Inbox", isOn: Binding(get: { !model.layout.inboxHidden }, set: { model.setInboxHidden(!$0) }))
                Toggle("Show the built-in searches in Views (Authored by me, Assigned to me, ...)", isOn: Binding(
                    get: { !model.layout.quickSearchesHidden }, set: { model.setQuickSearchesHidden(!$0) }))
                Toggle("Show Views", isOn: Binding(get: { !model.layout.savedViewsHidden }, set: { model.setSavedViewsHidden(!$0) }))
                Divider()
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
                                    CountBadges(counts: model.counts[source.id])
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
            HStack {
                Text("Hidden sources are kept and can be shown again at any time.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480, height: 620)
    }
}
