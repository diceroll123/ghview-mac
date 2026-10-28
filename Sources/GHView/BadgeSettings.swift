import SwiftUI
import GHCore

/// One item in an ordered, independently-toggleable badge list (e.g. what to show under a repo's name, or next
/// to a sidebar source). `UserDefaults` has no native support for ordered collections, so these are persisted
/// as JSON, the same way `SourceCatalog` and `SidebarLayout` are.
struct BadgeEntry<Item: Codable & Hashable & Sendable>: Codable, Identifiable, Hashable, Sendable {
    var item: Item
    var enabled: Bool
    /// Only meaningful for badges that can render as a filled pill (currently just the sidebar source
    /// badges); harmless and unused for ones that can't (the repo subtitle line is plain text).
    var color: BadgeColor = .plain
    var id: Item { item }
}

extension Array {
    func enabled<Item>() -> [Item] where Element == BadgeEntry<Item> { filter(\.enabled).map(\.item) }
}

/// A curated, Finder-tag-like palette for badges that can render as a filled pill. "Plain" means exactly
/// that: a bare numeral, no pill. No "Automatic" - what's picked is what shows, the same way System
/// Settings' own accent-color swatches work, not a hidden per-badge default that looks identical to one of
/// the explicit choices half the time.
enum BadgeColor: String, CaseIterable, Codable, Sendable {
    case plain, accent, red, orange, yellow, green, blue, purple, gray

    var label: String {
        switch self {
        case .plain: "Plain"
        case .accent: "Accent"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    /// The pill's fill color, or nil for `.plain` (no pill at all).
    var fill: Color? {
        switch self {
        case .plain: nil
        case .accent: .accentColor
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}

/// A reorderable list of toggles, for editing a `[BadgeEntry<Item>]` setting: drag to reorder, check to show,
/// and - when `showsColor` is on - a compact dropdown per item, the same closed-button-that-opens-a-
/// checkmarked-list pattern System Settings uses for its own tint-color pickers (not a permanently-expanded
/// row of swatches).
struct BadgeOrderEditor<Item: Hashable & Codable & Sendable>: View {
    @Binding var entries: [BadgeEntry<Item>]
    var showsColor = false
    var colorable: (Item) -> Bool = { _ in true }
    var hint: (Item) -> String? = { _ in nil }
    let label: (Item) -> String

    var body: some View {
        List {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    Toggle(isOn: binding(for: entry.item)) { Text(label(entry.item)).lineLimit(1) }
                        .help(hint(entry.item) ?? "")
                    if showsColor && colorable(entry.item) {
                        Spacer(minLength: 8)
                        colorPicker(for: entry.item).layoutPriority(1)
                    }
                }
            }
            .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .frame(height: CGFloat(entries.count) * 24 + 8)
    }

    private func binding(for item: Item) -> Binding<Bool> {
        Binding(
            get: { entries.first { $0.item == item }?.enabled ?? false },
            set: { newValue in
                guard let i = entries.firstIndex(where: { $0.item == item }) else { return }
                entries[i].enabled = newValue
            }
        )
    }

    private func colorBinding(for item: Item) -> Binding<BadgeColor> {
        Binding(
            get: { entries.first { $0.item == item }?.color ?? .plain },
            set: { newValue in
                guard let i = entries.firstIndex(where: { $0.item == item }) else { return }
                entries[i].color = newValue
            }
        )
    }

    private func colorPicker(for item: Item) -> some View {
        Picker("Color", selection: colorBinding(for: item)) {
            ForEach(BadgeColor.allCases, id: \.self) { c in
                Label(c.label, systemImage: c == .plain ? "circle.dashed" : "circle.fill")
                    .tint(c.fill ?? .secondary)
                    .tag(c)
            }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }
}

// MARK: Repo name subtitle

/// What can appear under a repository's name in the Repo Browser pane (not the sidebar tree, which keeps
/// repo rows icon-only).
enum RepoSubtitleItem: String, CaseIterable, Codable, Sendable {
    case language, releaseTag, releaseDate, lastUpdated, lockIcon

    var label: String {
        switch self {
        case .language: "Language"
        case .releaseTag: "Latest release tag"
        case .releaseDate: "Latest release date"
        case .lastUpdated: "Last updated"
        case .lockIcon: "Lock icon for private repositories"
        }
    }

    /// Matches what was always shown before this was configurable: just the language, plus the lock icon that
    /// `RepoFlags` already drew unconditionally.
    static let defaultEntries: [BadgeEntry<RepoSubtitleItem>] = [
        BadgeEntry(item: .language, enabled: true),
        BadgeEntry(item: .releaseTag, enabled: false),
        BadgeEntry(item: .releaseDate, enabled: false),
        BadgeEntry(item: .lastUpdated, enabled: false),
        BadgeEntry(item: .lockIcon, enabled: true),
    ]
}

/// The configured, ordered line of text badges under a repository's name. The lock icon is configured here too,
/// but drawn by `RepoFlags` instead of inline, so it stays a small icon rather than becoming a word in the line.
struct RepoSubtitleLine: View {
    let repo: RepoInfo
    let items: [RepoSubtitleItem]

    private var parts: [Text] {
        items.compactMap { item in
            switch item {
            case .language: repo.language.map(Text.init)
            case .releaseTag: repo.releaseTag.map(Text.init)
            case .releaseDate: repo.releaseDate.map { Text("Released ") + Text($0, format: .relative(presentation: .named)) }
            case .lastUpdated: repo.pushedAt.map { Text("Updated ") + Text($0, format: .relative(presentation: .named)) }
            case .lockIcon: nil  // shown by RepoFlags, not as text
            }
        }
    }

    var body: some View {
        if !parts.isEmpty {
            HStack(spacing: 6) {
                ForEach(parts.indices, id: \.self) { i in
                    if i > 0 { Bullet() }
                    parts[i]
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A fake repo row in Settings, showing exactly what the current order and on/off choices will look like, so
/// there's no need to go find a real repo to check.
struct RepoSubtitlePreview: View {
    let entries: [BadgeEntry<RepoSubtitleItem>]

    private static let sample = RepoInfo(
        id: RepoId(owner: "octocat", name: "example-repo"), language: "Swift",
        pushedAt: Date().addingTimeInterval(-3 * 3600), stars: 128, isPrivate: true,
        releaseTag: "v2.1.0", releaseDate: Date().addingTimeInterval(-2 * 86400))

    var body: some View {
        HStack(spacing: 8) {
            LanguageIcon(language: Self.sample.language)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.sample.id.name)
                RepoSubtitleLine(repo: Self.sample, items: entries.enabled().filter { $0 != .lockIcon })
            }
            Spacer(minLength: 0)
            if entries.first(where: { $0.item == .lockIcon })?.enabled == true {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Sidebar source badges

/// What can appear as a trailing badge on a sidebar source or group row.
enum SourceBadgeItem: String, CaseIterable, Codable, Sendable {
    case reviewRequested, openPRs, repoCount

    var label: String {
        switch self {
        case .reviewRequested: "PRs waiting for your review"
        case .openPRs: "Open pull requests"
        case .repoCount: "Number of repositories"
        }
    }

    /// Matches what was always shown before this was configurable: a filled accent pill for the one count
    /// that means "needs you", plain numerals for the rest.
    static let defaultEntries: [BadgeEntry<SourceBadgeItem>] = [
        BadgeEntry(item: .reviewRequested, enabled: true, color: .accent),
        BadgeEntry(item: .openPRs, enabled: true, color: .plain),
        BadgeEntry(item: .repoCount, enabled: false, color: .plain),
    ]
}

/// Shows exactly what the current order and on/off choices will look like, right above the controls that
/// edit them. Just `CountBadges` on a fake row, so it updates live as entries are toggled or reordered - it
/// reads the same settings `CountBadges` does everywhere else, not a copy of its logic.
struct SourceBadgePreview: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill").font(.title3).foregroundStyle(.secondary)
            Text("example-org")
            Spacer(minLength: 0)
            CountBadges(counts: SourceCounts(open: 7, reviewRequested: 2), repoCount: 12)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
