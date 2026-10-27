import SwiftUI
import GHCore

/// Wraps its children onto new lines when they do not fit, so the bar works in a narrow inspector.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return (origins, CGSize(width: width, height: y + rowHeight))
    }
}

/// Every PR action as a visible button. Buttons that cannot run are disabled, with the reason as their tooltip.
struct ActionBar: View {
    @Environment(AppModel.self) private var model
    let targets: [PR]

    private var allAutoMerging: Bool { !targets.isEmpty && targets.allSatisfy(\.autoMerge) }

    var body: some View {
        @Bindable var model = model
        FlowLayout(spacing: 6) {
            action(.approve, "Approve", "checkmark.circle", tint: .green)
            // Merge controls only appear when merging is possible for the selection.
            let canMerge = model.offers(.merge, for: targets)
            let canAuto = model.offers(.autoMerge, for: targets)
            if canMerge {
                action(.merge, "Merge", "arrow.triangle.merge", tint: .purple, prominent: true, help: "Merge now (\(model.mergeMethodSummary(for: targets)))")
            }
            if allAutoMerging {
                if model.offers(.disableAutoMerge, for: targets) { action(.disableAutoMerge, "Cancel auto-merge", "bolt.slash.fill", tint: .orange) }
            } else if canAuto {
                action(.autoMerge, "Auto-merge", "bolt.fill", tint: .purple,
                       help: "Merge automatically once checks pass and reviews are satisfied (\(model.mergeMethodSummary(for: targets)))")
            }
            if canMerge || canAuto { mergeMethodMenu }
            action(.rebase, "Rebase", "arrow.triangle.2.circlepath")
            if targets.contains(where: \.isDraft) { action(.markReady, "Ready for review", "checkmark.seal") }
            if targets.contains(where: { !$0.isOpen }) { action(.reopen, "Reopen", "arrow.counterclockwise.circle") }
            if targets.contains(where: \.isOpen) { action(.close, "Close", "xmark.circle", tint: .red) }
            if targets.contains(where: \.isDependabot) {
                Menu {
                    ForEach(Dependabot.commands, id: \.key) { c in
                        Button(c.label) { model.dependabot(c.comment, on: targets) }
                    }
                } label: { Label("Dependabot", systemImage: "shippingbox") }
                    .menuStyle(.button).controlSize(.small).fixedSize()
            }
            Button { model.open(targets) } label: { Label("Open in browser", systemImage: "safari") }
                .labelStyle(.iconOnly).help("Open in browser")
            Button { model.copyURLs(targets) } label: { Label("Copy URL", systemImage: "link") }
                .labelStyle(.iconOnly).help("Copy URL")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private var mergeMethodMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Merge method", selection: $model.mergeMethod) {
                ForEach(MergeMethod.allCases, id: \.self) { method in
                    Text(method.title).tag(method)
                        .disabled(!targets.isEmpty && !targets.contains { model.repoInfo(for: $0.repo)?.allowedMergeMethods.contains(method) ?? true })
                }
            }
            .pickerStyle(.inline)
        } label: { Label(model.mergeMethod.title, systemImage: "arrow.triangle.branch") }
            .menuStyle(.button).controlSize(.small).fixedSize()
            .help("How Merge and Auto-merge combine commits. Repositories that disallow it use the nearest allowed method.")
    }

    @ViewBuilder
    private func action(_ action: PrAction, _ title: String, _ icon: String, tint: Color? = nil,
                        prominent: Bool = false, help: String? = nil) -> some View {
        let reason = model.unavailableReason(action, for: targets)
        let button = Button { model.perform(action, on: targets) } label: { Label(title, systemImage: icon) }
            .tint(tint)
            .disabled(reason != nil)
            .help(reason ?? help ?? title)
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }
}
