import SwiftUI
import GHCore

/// A login with a small person glyph, indigo for bots. The name uses the primary color, which keeps it distinct
/// from the dimmer `repo#123` reference beside it.
struct AuthorLabel: View {
    let login: String
    var bold = false

    var body: some View {
        let bot = Accounts.isBot(login)
        HStack(spacing: 3) {
            Image(systemName: "person.fill").font(.system(size: 9)).foregroundStyle(bot ? Color.indigo : Color.secondary)
            Text(login).fontWeight(bold ? .semibold : .regular).foregroundStyle(.primary).lineLimit(1)
        }
        .help(bot ? "\(login) (bot)" : login)
    }
}

/// A soft highlight that sweeps across redacted placeholders while content loads.
///
/// Driven by the wall clock rather than per-view state, so every placeholder on screen shares one phase and the
/// sweep reads as a single wave. Honors Reduce Motion by showing a still, slightly dimmed placeholder.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var period: Double = 1.4

    func body(content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.6)
        } else {
            TimelineView(.animation) { context in
                // 0...1 across one sweep; the band is one view-width wide and travels from left of the view to right of it
                let phase = (context.date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
                content.mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.25), location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .black.opacity(0.25), location: 1),
                        ],
                        startPoint: UnitPoint(x: phase * 3 - 1.5, y: 0.5),
                        endPoint: UnitPoint(x: phase * 3 - 0.5, y: 0.5)
                    )
                )
            }
        }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// A source's GitHub avatar: a circle for users, a rounded square for orgs, with the old glyph as a placeholder
/// while loading or if it cannot be fetched.
struct AvatarView: View {
    @Environment(AvatarStore.self) private var store
    let source: Source
    var size: CGFloat = 18

    var body: some View {
        let url = source.avatarURL(pixels: Int(size * 4)) // 2x retina with headroom
        Group {
            if let image = store.image(for: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: { switch source { case .user: "person.fill"; case .org: "building.2.fill"; case .repo: "book.closed.fill" } }())
                    .font(.system(size: size * 0.55)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 0.5))
        .task(id: url) { await store.load(url) }
        .accessibilityHidden(true)
    }

    private var shape: AnyShape {
        if case .user = source { AnyShape(Circle()) } else { AnyShape(RoundedRectangle(cornerRadius: size * 0.22)) }
    }
}

/// Stand-in avatar while a name is being typed or looked up.
struct AvatarPlaceholder: View {
    var symbol = "person.crop.square"
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45)).foregroundStyle(.tertiary)
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}

struct CheckIcon: View {
    let status: CheckStatus
    var body: some View {
        Image(systemName: symbol).foregroundStyle(color).help(status.rawValue.capitalized)
    }
    private var symbol: String {
        switch status {
        case .passing: "checkmark.circle.fill"
        case .failing, .cancelled: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .skipped: "minus.circle.fill"
        case .unknown: "circle.dotted"
        }
    }
    private var color: Color {
        switch status {
        case .passing: .green
        case .failing: .red
        case .cancelled: .gray
        case .pending: .orange
        case .skipped: .gray.opacity(0.6)
        case .unknown: .secondary
        }
    }
}

struct MergeBadge: View {
    let state: MergeableState
    var body: some View {
        switch state {
        case .behind: Label("rebase", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .dirty: Label("conflicts", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .blocked: Label("blocked", systemImage: "nosign").foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}

struct ReviewBadge: View {
    let status: ReviewStatus
    var body: some View {
        switch status {
        case .approved: Label("approved", systemImage: "checkmark.seal").foregroundStyle(.green)
        case .changesRequested: Label("changes", systemImage: "pencil.circle").foregroundStyle(.red)
        default: EmptyView()
        }
    }
}

struct LabelChip: View {
    let label: PRLabel
    var body: some View {
        let color = Color(hex: label.color)
        Text(label.name).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.25), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.6)))
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
