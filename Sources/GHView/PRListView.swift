import SwiftUI
import GHCore

struct PRListView: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: PrId?
    /// Shared by every row's separator, so the table's inset is measured once per list, not once per row.
    @State private var rowMargin: CGFloat = PRRowSeparator.defaultMargin

    var body: some View {
        @Bindable var model = model
        List(selection: $model.focused) {
                ForEach(Array(model.visiblePRs.enumerated()), id: \.element.id) { index, pr in
                    PRRow(pr: pr, hovered: hovered == pr.id)
                        .prRowSeparator(margin: $rowMargin, measures: index == 0)
                        .tag(pr.id)
                        .onHover { hovered = $0 ? pr.id : (hovered == pr.id ? nil : hovered) }
                        .contextMenu { PRActionsMenu(targets: model.contextTargets(for: pr)) }
                }
                if model.prsLoading && !model.hasLoadedPRs {
                    ForEach(0..<6, id: \.self) { SkeletonRow(index: $0).prRowSeparator(margin: $rowMargin, measures: $0 == 0 && model.visiblePRs.isEmpty) }
                }
                if model.hasMorePRs {
                    HStack {
                        Spacer()
                        if model.prsLoadingMore { ProgressView().controlSize(.small) }
                        else { Button("Load more") { model.loadPRs(more: true) }.buttonStyle(.link).disabled(model.prsLoading) }
                        Spacer()
                    }
                }
            }
            .overlay {
                switch model.listEmptyState {
                case .failed:
                    ContentUnavailableView {
                        Label("Could not load PRs", systemImage: "exclamationmark.triangle")
                    } actions: { Button("Retry") { model.refresh() } }
                case .noMatches:
                    ContentUnavailableView {
                        Label("No matching PRs", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(model.hasMorePRs
                             ? "None of the \(model.prs.count) loaded PRs match. More PRs have not been loaded."
                             : "None of the \(model.prs.count) PRs match the filter.")
                    } actions: {
                        Button("Clear filter") { model.filter = "" }
                        if model.hasMorePRs { Button("Load all") { Task { await model.loadAllPRs() } } }
                    }
                case .noOpenPRs:
                    ContentUnavailableView(model.isSearchDestination ? "No open PRs match this search" : (model.destination.map(\.isInbox) == true ? "Nothing here" : "No open PRs"),
                                           systemImage: "checkmark.circle")
                case nil:
                    EmptyView()
                }
            }
            .overlay(alignment: .bottom) {
                if let progress = model.batchProgress {
                    BatchProgressHUD(progress: progress).padding(.bottom, 14)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.batchProgress)
            .onKeyPress(.space) {
                if let id = model.focused { model.selection.toggle(id); return .handled }
                return .ignored
            }
            .onKeyPress(.escape) { model.selection.clear(); return .handled }
            .focusedValue(\.prList, PRListCommands(selectAll: { model.selection.selectAll(visible: model.visiblePRs.map(\.id)) }))
            // Header and selection bar are insets of the list, so it keeps its full height.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PRListHeader()
                    Divider()
                    if model.viewIsPartial { PartialViewNotice() }
                    if !model.prFailures.isEmpty { SourceFailureNotice(failures: model.prFailures.map { ($0.scope, $0.message) }) { model.retryFailedSources() } }
                    if let gap = model.searchShortfall { SearchLimitNotice(received: gap.received, total: gap.total) }
                    if model.selection.isSelectionMode { SelectionBar() }
                }
                .solidBarBackground()
            }
    }
}

/// The separator between the pieces of a row's detail line: `repo#12 \u{2022} author \u{2022} Updated 4 minutes ago`.
struct Bullet: View {
    var body: some View {
        Text(verbatim: "\u{2022}").foregroundStyle(.secondary).accessibilityHidden(true)
    }
}

struct PRRow: View {
    @Environment(AppModel.self) private var model
    let pr: PR
    let hovered: Bool

    var body: some View {
        let showBox = model.selection.showsCheckbox(for: pr.id, focused: model.focused, hovered: hovered ? pr.id : nil)
        let checked = model.selection.selected.contains(pr.id)
        HStack(alignment: .top, spacing: 8) {
            Button {
                if NSEvent.modifierFlags.contains(.shift) {
                    model.selection.selectRange(to: pr.id, in: model.visiblePRs.map(\.id))
                } else { model.selection.toggle(pr.id) }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(showBox ? 1 : 0)
            .allowsHitTesting(showBox)

            CheckIcon(status: pr.checkSummary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(pr.title).lineLimit(2).fontWeight(.medium)
                    if pr.isDraft { Text("Draft").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                }
                // A plain HStack squished these onto one line and clipped or overlapped when the row was
                // narrow (e.g. the PR list beside the repo browser); wrapping to a second line instead keeps
                // everything legible at any width.
                FlowLayout(spacing: 6) {
                    Text(verbatim: model.label(for: pr))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    RepoFlags(repo: model.repoInfo(for: pr.repo), showsPrivate: false, showsFork: false)
                    Bullet()
                    AuthorLabel(login: pr.author)
                    Bullet()
                    (Text("Updated ") + Text(pr.updatedAt, format: .relative(presentation: .named))).foregroundStyle(.secondary)
                        .lineLimit(1)
                    if pr.comments > 0 { Label("\(pr.comments)", systemImage: "bubble").labelStyle(.titleAndIcon) }
                    Text("+\(pr.additions)").foregroundStyle(.green)
                    Text("-\(pr.deletions)").foregroundStyle(.red)
                    MergeBadge(state: pr.mergeable)
                    ReviewBadge(status: pr.reviewStatus)
                }
                .font(.caption)
                if !pr.labels.isEmpty {
                    HStack { ForEach(pr.labels, id: \.name) { LabelChip(label: $0) } }
                }
            }
        }
        .opacity(pr.isDraft ? 0.65 : 1)
    }
}

/// The separator under a PR row, drawn as part of the row's own content.
///
/// The table's own separators are painted separately from the rows and went missing or ended short under some
/// rows after the list was resized, scrolled or reloaded. A line that belongs to the row repaints with it, so it
/// can never be clipped on its own. The table's separator and its vertical row inset are turned off, and this
/// supplies both, so the line sits exactly on the row's bottom edge and spans the row's full width.
struct PRRowSeparator: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    /// The table's inset as measured on this machine and window; `defaultMargin` until a measurement is available.
    /// Shared across every row (bound from `PRListView`) so only one row ever measures it - remeasuring it from
    /// every row as each one first appeared caused each of them to shift a frame late while scrolling.
    @Binding var margin: CGFloat
    /// Only one row per list needs to probe the table; the rest just draw with whatever it found.
    var measures: Bool = false

    func body(content: Content) -> some View {
        content
            // A row sizes to its contents, so without this the line below would only be as wide as the title.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6) // the table's own 4pt inset plus the row's 2pt, so the row keeps its height
            .background {
                if measures { GeometryReader { geo in TableMarginProbe(cellWidth: geo.size.width, margin: $margin) } }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1 / displayScale)
                    .padding(.horizontal, -margin) // out to the table's own edges, past the cell
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets()) // the default horizontal insets are zero, so only the vertical ones change
    }

    /// What the table was measured to inset a row's content on the development machine (a 587pt table had a 555pt
    /// cell). It is only the starting value: the real inset is measured from the table at run time, because it
    /// can differ between macOS versions and list styles.
    static let defaultMargin: CGFloat = 16

    /// The inset implied by a table and cell width, or nil if the numbers are implausible (a half-laid-out
    /// list), in which case the previous value is kept. A wrong guess here would draw the line outside the list.
    static func margin(tableWidth: CGFloat, cellWidth: CGFloat) -> CGFloat? {
        guard tableWidth > 0, cellWidth > 0 else { return nil }
        let m = ((tableWidth - cellWidth) / 2).rounded()
        return (0...40).contains(m) ? m : nil
    }
}

/// Reads the table's real horizontal inset by comparing the enclosing scroll view's width with the row's own.
private struct TableMarginProbe: NSViewRepresentable {
    let cellWidth: CGFloat
    @Binding var margin: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let cellWidth = cellWidth
        DispatchQueue.main.async {
            guard let table = view.enclosingScrollView?.contentView.bounds.width,
                  let m = PRRowSeparator.margin(tableWidth: table, cellWidth: cellWidth), abs(m - margin) >= 0.5 else { return }
            margin = m
        }
    }
}

extension View {
    func prRowSeparator(margin: Binding<CGFloat>, measures: Bool = false) -> some View {
        modifier(PRRowSeparator(margin: margin, measures: measures))
    }
}

/// Filters and sorts work on the PRs loaded so far; this says so and offers the complete view.
struct PartialViewNotice: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Filtering and sorting only the \(model.prs.count) loaded PRs. More exist.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.loadingAllPRs { ProgressView().controlSize(.small) }
            else { Button("Load all") { Task { await model.loadAllPRs() } }.controlSize(.small) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

/// Some sources failed while the rest loaded; says which, and retries just those.
struct SourceFailureNotice: View {
    let failures: [(name: String, message: String)]
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(failures.count) source\(failures.count == 1 ? "" : "s") could not be loaded; the rest are shown.")
                    .font(.caption).fontWeight(.medium)
                ForEach(failures, id: \.name) { f in
                    Text("\(f.name): \(f.message)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button("Retry", action: retry).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

/// GitHub serves at most 1,000 results per search; when a slice of the results is still beyond that, say so.
struct SearchLimitNotice: View {
    let received: Int
    let total: Int
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("GitHub limits search results: only \(received) of \(total) matching PRs can be reached. Select fewer sources, or one repository, to see the rest.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

struct SelectionBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let targets = model.actionTargets
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(model.selection.count) selected").fontWeight(.semibold)
                if model.hiddenSelectedCount > 0 {
                    Text("(\(model.hiddenSelectedCount) hidden by the filter)").foregroundStyle(.orange).font(.caption)
                    Button("Deselect hidden") {
                        model.selection.deselect(model.selection.hidden(from: model.visiblePRs.map(\.id)))
                    }.controlSize(.small)
                }
                Spacer()
                Button("Clear") { model.selection.clear() }.controlSize(.small)
            }
            ActionBar(targets: targets).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.bar)
    }
}

struct PRActionsMenu: View {
    @Environment(AppModel.self) private var model
    let targets: [PR]

    var body: some View {
        Group {
            Button { model.perform(.approve, on: targets) } label: { Label("Approve", systemImage: "checkmark.circle") }
            if model.offers(.merge, for: targets) {
                Button { model.perform(.merge, on: targets) } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
            }
            if targets.allSatisfy(\.autoMerge) {
                if model.offers(.disableAutoMerge, for: targets) {
                    Button { model.perform(.disableAutoMerge, on: targets) } label: { Label("Cancel auto-merge", systemImage: "bolt.slash.fill") }
                }
            } else if model.offers(.autoMerge, for: targets) {
                Button { model.perform(.autoMerge, on: targets) } label: { Label("Auto-merge", systemImage: "bolt.fill") }
            }
            Button { model.perform(.rebase, on: targets) } label: { Label("Rebase", systemImage: "arrow.triangle.2.circlepath") }
            Button { model.perform(.markReady, on: targets) } label: { Label("Mark ready", systemImage: "checkmark.seal") }
            Button { model.perform(.close, on: targets) } label: { Label("Close", systemImage: "xmark.circle") }
            Button { model.perform(.reopen, on: targets) } label: { Label("Reopen", systemImage: "arrow.counterclockwise.circle") }
            if targets.contains(where: \.isDependabot) {
                Menu {
                    ForEach(Dependabot.commands, id: \.key) { c in
                        Button(c.label) { model.dependabot(c.comment, on: targets) }
                    }
                } label: { Label("Dependabot", systemImage: "shippingbox") }
            }
            Divider()
            Button { model.open(targets) } label: { Label("Open in browser", systemImage: "safari") }
            Button { model.copyURLs(targets) } label: { Label("Copy URL", systemImage: "link") }
            if let repo = targets.first?.repo, Set(targets.map(\.repo)).count == 1 {
                Divider()
                Menu { RepoContextMenu(repo: repo) } label: { Label(repo.fullName, systemImage: "book.closed") }
            }
        }
    }
}

/// Header lives inside the PR pane so it lines up with the list instead of floating in the window toolbar.
struct PRListHeader: View {
    @Environment(AppModel.self) private var model
    @State private var showFilters = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            if model.isSearchDestination || model.isInboxDestination { searchTitle }
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    if let query = model.inboxQueryText {
                        // The section's own rules decide the list; this is the nearest GitHub search, for reference.
                        Text(verbatim: query).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .help(model.inboxQueryNote ?? "The GitHub search equivalent to this section")
                    } else if model.isSearchDestination {
                        TextField("GitHub search, e.g. label:bug org:acme", text: $model.searchText)
                            .textFieldStyle(.plain).autocorrectionDisabled()
                            .onSubmit { model.loadPRs() }
                        if model.searchText != (model.defaultSearchText ?? "") {
                            Button { model.searchText = model.defaultSearchText ?? "" } label: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Back to the original search")
                        }
                    } else {
                        TextField("Filter: text, author:, label:, is:draft...", text: $model.filter)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                        if model.isFiltering {
                            Text("\(model.visiblePRs.count) of \(model.prs.count)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear filter")
                        }
                        Button { showFilters.toggle() } label: {
                            Image(systemName: model.isFiltering
                                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.isFiltering ? Color.accentColor : .secondary)
                        .help("Filter by author, label, status...")
                        .popover(isPresented: $showFilters, arrowEdge: .bottom) { FilterPopover() }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                // A menu with our own label rather than a Picker: the Picker's popup button took whatever width the
                // search field left it and collapsed to a few pixels. A label view keeps its natural width.
                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(PRSort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(model.sort.rawValue).lineLimit(1)
                }
                .menuStyle(.button)
                .fixedSize()
                .layoutPriority(1)
                .help("Sort the list")
                Button { model.refresh() } label: {
                    if model.prsLoading && model.hasLoadedPRs { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 20)
                .disabled(model.prsLoading)
                .help("Refresh")
            }
            // Shown as text, not behind an icon: a hover or a click on a tiny control was not reliable in this strip.
            if let note = model.inboxQueryNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.searchError {
                Label("GitHub could not run this search: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(8)
        // Typing a search waits for a pause, then runs it. A query the list already shows is not run again.
        .task(id: model.searchText) {
            guard model.isSearchDestination else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let wanted = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if wanted != (model.lastLoadedQuery ?? "") { model.loadPRs() }
        }
    }

    /// The panel is already named by the window's title (the destination's name), so this row only exists to offer
    /// keeping an edited saved view's search.
    @ViewBuilder private var searchTitle: some View {
        if case .savedView(let id) = model.destination,
           let view = model.layout.savedViews.first(where: { $0.id == id }),
           model.searchText.trimmingCharacters(in: .whitespacesAndNewlines) != view.query,
           !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack {
                Spacer()
                Button("Save changes to view") { try? model.updateView(id, name: view.name, query: model.searchText) }
                    .controlSize(.small)
            }
        }
    }
}

/// Placeholder row shown while the first page loads.
struct SkeletonRow: View {
    let index: Int

    /// Different title lengths, so the placeholders do not look like copies of one row.
    private static let titles = [
        "feat: placeholder pull request title goes here",
        "fix: shorter placeholder title",
        "chore: placeholder pull request title that runs a bit longer",
        "feat: placeholder title",
        "fix: another placeholder pull request title",
        "chore: placeholder",
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").opacity(0)
            Image(systemName: "circle.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.titles[index % Self.titles.count]).fontWeight(.medium)
                Text("#123  author  2 hours ago  +10 -2").font(.caption)
            }
        }
        .redacted(reason: .placeholder)
        .shimmering()
        .accessibilityHidden(true)
    }
}

/// Checkboxes that edit the same query string as the text field, so typing and clicking stay in sync.
struct FilterPopover: View {
    @Environment(AppModel.self) private var model

    private var authors: [(name: String, count: Int)] { counts(model.prs.map(\.author)) }
    private var labels: [(name: String, count: Int)] { counts(model.prs.flatMap { $0.labels.map(\.name) }) }

    private func counts(_ values: [String]) -> [(name: String, count: Int)] {
        Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
            .map { (name: $0.key, count: $0.value) }
            .sorted { ($1.count, $0.name.lowercased()) < ($0.count, $1.name.lowercased()) }
    }

    private func check(_ title: String, _ token: String, count: Int? = nil, author: Bool = false) -> some View {
        Toggle(isOn: Binding(get: { model.filterHas(token) }, set: { _ in model.toggleFilter(token) })) {
            HStack {
                if author { AuthorLabel(login: title) } else { Text(title).lineLimit(1) }
                if let count { Spacer(); Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .toggleStyle(.checkbox)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filter").font(.headline)
                Spacer()
                Button("Clear all") { model.filter = "" }.disabled(model.filter.isEmpty).buttonStyle(.link)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Quick") {
                        check("Only mine", FilterQuery.token(.author, "@me"))
                        check("Hide bots", FilterQuery.token(.is, "bot", negated: true))
                        check("Needs my review (directly requested)", FilterQuery.token(.reviewer, "@me"))
                    }
                    if !authors.isEmpty {
                        section("Author") {
                            ForEach(authors, id: \.name) { a in check(a.name, FilterQuery.token(.author, a.name), count: a.count, author: true) }
                        }
                    }
                    if !labels.isEmpty {
                        section("Label") {
                            ForEach(labels, id: \.name) { l in check(l.name, FilterQuery.token(.label, l.name), count: l.count) }
                        }
                    }
                    section("Status") {
                        check("Draft", FilterQuery.token(.is, "draft"))
                        check("Ready for review", FilterQuery.token(.is, "ready"))
                        check("Has conflicts", FilterQuery.token(.is, "conflicts"))
                        check("Behind base", FilterQuery.token(.is, "behind"))
                        check("Auto-merge on", FilterQuery.token(.is, "automerge"))
                    }
                    section("Checks") {
                        check("Passing", FilterQuery.token(.checks, "passing"))
                        check("Failing", FilterQuery.token(.checks, "failing"))
                        check("Pending", FilterQuery.token(.checks, "pending"))
                    }
                    section("Review") {
                        check("Approved", FilterQuery.token(.review, "approved"))
                        check("Changes requested", FilterQuery.token(.review, "changes"))
                        check("Review required", FilterQuery.token(.review, "pending"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Same author, label or status options match any of them; different groups must all match. Prefix a token with - to exclude it.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300, height: 460)
    }
}

/// A compact version of `ChecksBar`'s look for a running batch action: green for what has finished, the same
/// amber striped tail for what has not.
struct BatchProgressBar: View {
    let progress: BatchProgress
    var height: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { gc, size in
                let fraction = progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
                let doneWidth = size.width * fraction
                let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                gc.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
                if doneWidth > 0 {
                    gc.fill(Path(CGRect(x: 0, y: 0, width: doneWidth, height: size.height)), with: .color(CheckCounts.Kind.passed.color))
                }
                let remaining = CGRect(x: doneWidth, y: 0, width: size.width - doneWidth, height: size.height)
                gc.fill(Path(remaining), with: .color(CheckCounts.Kind.pending.color.opacity(0.3)))
                gc.drawLayer { layer in
                    layer.clip(to: Path(remaining))
                    ChecksBar.stripes(in: remaining, phase: phase, into: &layer)
                }
            }
        }
        .frame(height: height)
    }
}

/// Floats over the bottom of the list while a batch action (merge, close, a dependabot command, ...) is
/// running, instead of pushing the list's content up like a fixed status bar would.
struct BatchProgressHUD: View {
    let progress: BatchProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(progress.total > 1 ? "Working... \(progress.done)/\(progress.total)" : "Working...")
                .font(.caption).foregroundStyle(.secondary)
            BatchProgressBar(progress: progress).frame(width: 160)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
