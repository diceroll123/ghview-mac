import SwiftUI
import AppKit

/// Resizes the middle column when the Repos/PRs mode changes.
///
/// A column's ideal width is only applied the first time it is laid out, so a column that should be narrow for a
/// repo list and wide for a PR list cannot be expressed with `navigationSplitViewColumnWidth` alone. This moves
/// the divider on a mode change, but only if the column is still at the width we last chose: a width you set by
/// dragging, or one restored from the last session, is left alone.
struct ContentColumnWidth: NSViewRepresentable {
    /// In PRs mode the middle column holds the PR list and the detail pane fills the rest, so the two split the
    /// space beside the sidebar evenly. In repos mode the column is a plain repo list at a fixed, narrow width.
    let prsMode: Bool
    var reposWidth: CGFloat = 280
    var maxWidth: CGFloat = 760

    func makeNSView(context: Context) -> NSView { NSView() }

    /// The width we last chose is kept on the split view itself. SwiftUI can rebuild this helper when the mode
    /// changes, which would forget it and make every switch look like the first layout.
    private enum Association { nonisolated(unsafe) static var lastChosen = 0 }
    private static func lastChosen(on split: NSSplitView) -> CGFloat? {
        (objc_getAssociatedObject(split, &Association.lastChosen) as? NSNumber).map { CGFloat($0.doubleValue) }
    }
    private static func setLastChosen(_ width: CGFloat, on split: NSSplitView) {
        objc_setAssociatedObject(split, &Association.lastChosen, NSNumber(value: Double(width)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let prsMode = prsMode, reposWidth = reposWidth, maxWidth = maxWidth
        DispatchQueue.main.async {
            guard let split = Self.threeColumnSplit(from: view) else { return }
            let sidebar = split.arrangedSubviews[0].frame.width
            let middle = split.arrangedSubviews[1]
            // Space shared by the middle column and the detail pane, after the sidebar and the two dividers.
            let shared = split.bounds.width - sidebar - 2 * split.dividerThickness
            let width = prsMode ? min(maxWidth, (shared / 2).rounded()) : reposWidth
            let last = Self.lastChosen(on: split)
            defer { Self.setLastChosen(width, on: split) }
            // First layout: the column's own ideal width has just been applied.
            guard let last, last != width else { return }
            guard abs(middle.frame.width - last) < 12 else { return } // the user has their own width
            split.setPosition(sidebar + split.dividerThickness + width, ofDividerAt: 1)
        }
    }

    /// The window's sidebar | content | detail split, found by walking up from a view inside the content column.
    private static func threeColumnSplit(from view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let v = current {
            if let split = v as? NSSplitView, split.arrangedSubviews.count >= 3 { return split }
            current = v.superview
        }
        return nil
    }
}
