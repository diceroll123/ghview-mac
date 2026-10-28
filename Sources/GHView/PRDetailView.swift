import SwiftUI
import GHCore

struct PRDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", activity = "Activity", diff = "Diff"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .overview

    var body: some View {
        if let pr = model.focusedPR {
            VStack(spacing: 0) {
                ActionBar(targets: [pr])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.top, 8)
                Picker("Tab", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(8)
                Divider()
                switch tab {
                case .overview: overview(pr)
                case .activity: ActivityTab(pr: pr)
                case .diff: DiffTab(pr: pr)
                }
            }
        } else {
            ContentUnavailableView("Select a PR", systemImage: "arrow.triangle.pull")
        }
    }

    /// Title, a segmented progress bar, a legend and the individual check runs - all fetched lazily together
    /// (see `AppModel.loadChecks`), since even the breakdown behind the bar is real work for GitHub when a commit
    /// has hundreds of checks. `pr.checkSummary` (always present, from the rollup's cheap combined state) says
    /// at a glance whether there is anything to fetch at all.
    @ViewBuilder
    private func checksSection(_ pr: PR) -> some View {
        if pr.checkSummary == .unknown {
            Text("Checks").font(.headline)
            Text("No checks").foregroundStyle(.secondary)
        } else {
            switch model.checkRuns[model.checksKey(pr)] {
            case nil, .loading:
                HStack(alignment: .firstTextBaseline) {
                    Text("Checks").font(.headline)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            case .failed(let message):
                HStack(alignment: .firstTextBaseline) {
                    Text("Checks").font(.headline)
                    Spacer()
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.loadChecks(pr, force: true) } }
                }
            case .loaded(let runs, let counts):
                HStack(alignment: .firstTextBaseline) {
                    Text("Checks").font(.headline)
                    Spacer()
                    if !counts.isEmpty {
                        Text(verbatim: "\(counts.done) of \(counts.total) done").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if counts.isEmpty {
                    Text("No checks").foregroundStyle(.secondary)
                } else {
                    ChecksBar(counts: counts, height: 8)
                    ChecksLegend(counts: counts)
                    if runs.count < counts.total {
                        Text(verbatim: "Listing the first \(runs.count) of \(counts.total) checks")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(Self.actionableFirst(runs)) { check in
                        HStack {
                            CheckIcon(status: check.status)
                            Text(check.name)
                            Spacer()
                            if let url = check.url.flatMap(URL.init) { Link("Open", destination: url) }
                        }
                    }
                }
            }
        }
    }

    /// Failed first, then running, cancelled, passed, skipped: what needs attention is at the top.
    private static func actionableFirst(_ checks: [CheckRun]) -> [CheckRun] {
        func rank(_ s: CheckStatus) -> Int {
            switch s {
            case .failing: 0
            case .pending: 1
            case .cancelled: 2
            case .passing: 3
            case .skipped: 4
            case .unknown: 5
            }
        }
        return checks.enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
    }

    @ViewBuilder
    private func overview(_ pr: PR) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(pr.title).font(.title2).bold()
                    HStack {
                        Text(verbatim: "\(pr.repo.fullName)#\(pr.number)").foregroundStyle(.secondary)
                        Text("\(pr.headRef) -> \(pr.baseRef)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        HeadCommit(pr: pr)
                    }
                    HStack(spacing: 12) {
                        AuthorLabel(login: pr.author, bold: true)
                        Text("+\(pr.additions)").foregroundStyle(.green)
                        Text("-\(pr.deletions)").foregroundStyle(.red)
                        MergeBadge(state: pr.mergeable)
                        ReviewBadge(status: pr.reviewStatus)
                    }
                    if !pr.labels.isEmpty {
                        HStack {
                            ForEach(pr.labels, id: \.name) { LabelChip(label: $0) }
                            if pr.labelsTruncated, let total = pr.labelTotal {
                                Text("+\(total - pr.labels.count) more").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    reviewersSection(pr)
                    Divider()
                    checksSection(pr)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: model.checksKey(pr)) { await model.loadChecks(pr) }
            .task(id: model.activityKey(pr)) { await model.loadReviewers(pr) }
    }

    /// Who was asked to review. The total comes with every PR, so this can tell at a glance whether there is
    /// anything to show; the names themselves are fetched lazily unless the PR already carries them (the inbox's
    /// review-requested search does, to tell a direct request from a team one).
    @ViewBuilder
    private func reviewersSection(_ pr: PR) -> some View {
        let total = pr.reviewRequestTotal ?? 0
        if total > 0 {
            if !pr.requestedReviewers.isEmpty || !pr.requestedTeams.isEmpty {
                reviewersText(reviewers: pr.requestedReviewers, teams: pr.requestedTeams, total: total)
            } else {
                switch model.reviewRequests[model.activityKey(pr)] {
                case nil, .loading:
                    HStack { ProgressView().controlSize(.small); Text("Loading reviewers...").foregroundStyle(.secondary) }
                        .font(.callout)
                case .failed(let message):
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await model.loadReviewers(pr, force: true) } }
                    }
                case .loaded(let reviewers, let teams):
                    reviewersText(reviewers: reviewers, teams: teams, total: total)
                }
            }
        }
    }

    private func reviewersText(reviewers: [String], teams: [ReviewTeam], total: Int) -> some View {
        let names = reviewers + teams.map { "\($0.fullName) (team)" }
        let more = names.count < total ? ", +\(total - names.count) more" : ""
        return Text("Reviewers: " + names.joined(separator: ", ") + more).font(.callout)
    }
}

/// The PR's current head commit, abbreviated. Click to copy the full hash; right-click for the commit on GitHub.
struct HeadCommit: View {
    @Environment(AppModel.self) private var model
    let pr: PR

    var body: some View {
        Button { model.copy(pr.headSha) } label: {
            Label(pr.shortHeadSha, systemImage: "number")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Head commit \(pr.headSha). Click to copy.")
        .contextMenu {
            Button("Copy Full Hash") { model.copy(pr.headSha) }
            Button("Copy Short Hash") { model.copy(pr.shortHeadSha) }
            if let url = pr.headCommitURL { Button("Open Commit on GitHub") { NSWorkspace.shared.open(url) } }
        }
    }
}

struct DiffTab: View {
    @Environment(AppModel.self) private var model
    let pr: PR
    /// Files whose expanded state differs from the default (large files start collapsed).
    @State private var toggled: Set<String> = []

    private static let collapseThreshold = 400

    var body: some View {
        let key = model.diffKey(pr)
        Group {
            switch model.diffs[key] {
            case nil, .loading:
                ProgressView("Loading diff...").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not load diff", systemImage: "exclamationmark.triangle")
                } description: { Text(message) } actions: {
                    Button("Retry") { Task { await model.loadDiff(pr, force: true) } }
                }
            case .loaded(let files):
                if files.isEmpty {
                    ContentUnavailableView("No changes", systemImage: "doc")
                } else {
                    content(files, key: key)
                }
            }
        }
        .task(id: key) { toggled = []; await model.loadDiff(pr) }
    }

    private func isExpanded(_ f: DiffFile) -> Bool {
        (f.lineCount <= Self.collapseThreshold) != toggled.contains(f.id)
    }

    private func content(_ files: [DiffFile], key: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") changed").fontWeight(.medium)
                Text("+\(files.reduce(0) { $0 + $1.additions })").foregroundStyle(.green)
                Text("-\(files.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red)
                Spacer()
                Button("Reload") { Task { await model.loadDiff(pr, force: true) } }
                Button("Expand all") { toggled = Set(files.filter { $0.lineCount > Self.collapseThreshold }.map(\.id)) }
                Button("Collapse all") { toggled = Set(files.filter { $0.lineCount <= Self.collapseThreshold }.map(\.id)) }
            }
            .font(.callout).buttonStyle(.link)
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(files) { file in
                        Section {
                            if isExpanded(file) { FileBody(file: file, cacheKey: key) }
                        } header: {
                            FileHeader(file: file, expanded: isExpanded(file)) {
                                if !toggled.insert(file.id).inserted { toggled.remove(file.id) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct FileHeader: View {
    let file: DiffFile
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
                Image(systemName: icon).foregroundStyle(tint)
                Text(file.displayPath).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if file.isBinary { Text("binary").foregroundStyle(.secondary) }
                if let mode = file.modeChange { Text("mode \(mode)").foregroundStyle(.secondary) }
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("-\(file.deletions)").foregroundStyle(.red)
            }
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var icon: String {
        if file.isBinary { return "doc.zipper" }
        switch file.status {
        case .added: return "plus.square"
        case .deleted: return "minus.square"
        case .renamed: return "arrow.right.square"
        case .copied: return "plus.square.on.square"
        case .modified: return "pencil.square"
        }
    }
    private var tint: Color {
        switch file.status {
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        default: .secondary
        }
    }
}

struct FileBody: View {
    @Environment(\.colorScheme) private var scheme
    let file: DiffFile
    let cacheKey: String
    @State private var highlights: [Int: AttributedString] = [:]

    var body: some View {
        if file.hunks.isEmpty {
            Text(file.isBinary ? "Binary file not shown" : "No textual changes")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(file.hunks) { hunk in
                    HStack(spacing: 6) {
                        Text(hunk.header.split(separator: "@@", omittingEmptySubsequences: true).first.map { "@@\($0)@@" } ?? hunk.header)
                        Text(hunk.section).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10))
                    ForEach(hunk.lines) { DiffLineRow(line: $0, highlighted: highlights[$0.id]) }
                }
            }
            .textSelection(.enabled)
            .task(id: "\(cacheKey)|\(file.id)|\(scheme == .dark)") {
                highlights = await SyntaxEngine.shared.highlight(file: file, cacheKey: cacheKey, dark: scheme == .dark)
            }
        }
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    var highlighted: AttributedString?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker).frame(width: 14).foregroundStyle(.secondary)
            Text(highlighted ?? AttributedString(line.text.isEmpty ? " " : line.text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .monospaced))
        .background(background)
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
            .foregroundStyle(.secondary)
            .textSelection(.disabled)
    }
    private var marker: String {
        switch line.kind { case .added: "+"; case .removed: "-"; default: "" }
    }
    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.18)
        case .removed: .red.opacity(0.18)
        case .note: .secondary.opacity(0.08)
        case .context: .clear
        }
    }
}

// MARK: Activity

struct ActivityTab: View {
    @Environment(AppModel.self) private var model
    let pr: PR

    var body: some View {
        let key = model.activityKey(pr)
        VStack(spacing: 0) {
            Group {
                switch model.activities[key] {
                case nil, .loading:
                    ProgressView("Loading conversation...").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Could not load conversation", systemImage: "exclamationmark.triangle")
                    } description: { Text(message) } actions: {
                        Button("Retry") { Task { await model.loadActivity(pr, force: true) } }
                    }
                case .loaded(let activity):
                    timeline(activity)
                }
            }
            Divider()
            CommentComposer(pr: pr)
        }
        .task(id: key) { await model.loadActivity(pr) }
    }

    private func timeline(_ a: PRActivity) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Card(author: a.author, date: a.createdAt, badge: "description", url: nil) {
                    if a.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description provided.").foregroundStyle(.secondary).italic()
                    } else { MarkdownView(text: a.description) }
                }
                ForEach(a.items) { item in
                    Card(author: item.author, date: item.date, badge: badge(item.kind), tint: tint(item.kind), url: item.url) {
                        if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            EmptyView()
                        } else { MarkdownView(text: item.body) }
                    }
                }
                if !a.threads.isEmpty {
                    Text("Code comments").font(.headline).padding(.top, 6)
                    ForEach(a.threads) { ThreadCard(thread: $0) }
                }
                if a.truncated {
                    Label("Showing the first part of a long conversation. Open in browser to see all of it.",
                          systemImage: "ellipsis.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
    }

    private func badge(_ kind: ActivityItem.Kind) -> String? {
        guard case .review(let s) = kind else { return nil }
        switch s {
        case .approved: return "approved"
        case .changesRequested: return "requested changes"
        case .dismissed: return "dismissed review"
        case .commented: return "reviewed"
        case .pending: return "pending"
        }
    }
    private func tint(_ kind: ActivityItem.Kind) -> Color {
        guard case .review(let s) = kind else { return .secondary }
        switch s { case .approved: return Color.green; case .changesRequested: return Color.red; default: return Color.secondary }
    }
}

struct Card<Content: View>: View {
    let author: String
    let date: Date
    var badge: String?
    var tint: Color = .secondary
    let url: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AuthorLabel(login: author, bold: true)
                if let badge { Text(badge).font(.caption).foregroundStyle(tint) }
                Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = url.flatMap(URL.init) {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open on GitHub")
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(badge == nil ? 0.15 : 0.5)))
    }
}

struct ThreadCard: View {
    let thread: ReviewThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text(thread.line.map { "\(thread.path):\($0)" } ?? thread.path)
                    .font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if thread.isResolved { Text("resolved").font(.caption).foregroundStyle(.green) }
                if thread.isOutdated { Text("outdated").font(.caption).foregroundStyle(.orange) }
            }
            ForEach(thread.comments) { c in
                Divider()
                HStack(spacing: 6) {
                    AuthorLabel(login: c.author, bold: true)
                    Text(c.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
                MarkdownView(text: c.body)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .opacity(thread.isResolved ? 0.7 : 1)
    }
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownLite.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t):
                    Text(Self.attributed(t)).frame(maxWidth: .infinity, alignment: .leading)
                case .code(let c):
                    Text(c).font(.system(size: 11, design: .monospaced))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    static func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct CommentComposer: View {
    @Environment(AppModel.self) private var model
    let pr: PR

    private var draft: CommentDraft { model.drafts[pr.id] ?? CommentDraft() }
    private var text: Binding<String> {
        Binding(get: { model.draftText(for: pr.id) }, set: { model.setDraftText($0, for: pr.id) })
    }
    private var canPost: Bool { !draft.posting && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: text)
                .font(.body)
                .frame(height: 70)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if draft.text.isEmpty {
                        Text("Leave a comment (markdown supported)").foregroundStyle(.tertiary).padding(9).allowsHitTesting(false)
                    }
                }
                .disabled(draft.posting)
            if let error = draft.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("Cmd-Return to post").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if draft.posting { ProgressView().controlSize(.small) }
                Button("Comment") { let pr = pr; Task { await model.postDraft(for: pr) } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!canPost)
            }
        }
        .padding(10)
    }
}
