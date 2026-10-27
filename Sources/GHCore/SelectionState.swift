import Foundation

/// Multi-select model for the PR list.
/// Checkboxes show on the focused row until something is checked; after that they show on every row.
public struct SelectionState: Sendable, Equatable {
    public private(set) var selected: Set<PrId> = []
    public private(set) var anchor: PrId?

    public init() {}

    public var isSelectionMode: Bool { !selected.isEmpty }
    public var count: Int { selected.count }

    public func showsCheckbox(for id: PrId, focused: PrId?, hovered: PrId? = nil) -> Bool {
        isSelectionMode || id == focused || id == hovered
    }

    public mutating func toggle(_ id: PrId) {
        if !selected.insert(id).inserted { selected.remove(id) }
        anchor = id
    }

    /// Shift-click: select the inclusive range between the anchor and `id` in the visible order.
    public mutating func selectRange(to id: PrId, in visible: [PrId]) {
        guard let anchor, let a = visible.firstIndex(of: anchor), let b = visible.firstIndex(of: id) else {
            toggle(id); return
        }
        selected.formUnion(visible[min(a, b)...max(a, b)])
    }

    /// Cmd-A in the PR list: adds every visible PR. Pressing it again changes nothing; clearing is its own action.
    public mutating func selectAll(visible: [PrId]) { selected.formUnion(visible) }

    public mutating func clear() { selected = []; anchor = nil }

    /// Drops just these PRs, e.g. the ones a finished batch handled, leaving any selection made since untouched.
    public mutating func deselect<S: Sequence>(_ ids: S) where S.Element == PrId {
        selected.subtract(ids)
        if let a = anchor, !selected.contains(a) { anchor = nil }
    }

    /// Selected PRs that are not among `visible`, i.e. hidden by the filter but still targeted by a batch.
    public func hidden(from visible: [PrId]) -> Set<PrId> { selected.subtracting(visible) }

    /// Selected PRs in list order; selection survives sort and filter, hidden selections are kept.
    public func targets(in prs: [PR]) -> [PR] { prs.filter { selected.contains($0.id) } }
}
