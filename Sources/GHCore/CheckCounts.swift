import Foundation

/// How a PR's checks break down, for the segmented progress bar. Counts come from GitHub's per-state totals, so
/// they stay exact beyond the 100 checks we fetch individually.
public struct CheckCounts: Hashable, Sendable, Codable {
    public var passed = 0
    public var failed = 0
    public var skipped = 0
    public var cancelled = 0
    public var pending = 0
    /// States we do not recognise. They are drawn as `skipped`, but they stop the PR from reading as passing.
    public var unrecognized = 0

    public init(
        passed: Int = 0, failed: Int = 0, skipped: Int = 0, cancelled: Int = 0, pending: Int = 0,
        unrecognized: Int = 0
    ) {
        self.unrecognized = unrecognized
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.cancelled = cancelled
        self.pending = pending
    }

    /// Left to right on the bar: finished checks fill from the left, checks still running are the tail.
    public enum Kind: CaseIterable, Sendable {
        case passed, failed, skipped, cancelled, pending

        public var label: String {
            switch self {
            case .passed: "passed"
            case .failed: "failed"
            case .skipped: "skipped"
            case .cancelled: "cancelled"
            case .pending: "running"
            }
        }
    }

    public struct Segment: Equatable, Sendable {
        public var kind: Kind
        public var count: Int
        /// Share of all checks, 0...1.
        public var fraction: Double
    }

    public var total: Int { passed + failed + skipped + cancelled + pending }
    /// Checks that have finished, whatever the outcome.
    public var done: Int { total - pending }
    public var isEmpty: Bool { total == 0 }

    public func count(of kind: Kind) -> Int {
        switch kind {
        case .passed: passed
        case .failed: failed
        case .skipped: skipped
        case .cancelled: cancelled
        case .pending: pending
        }
    }

    /// The overall result, worst first: failed > cancelled > running > passing. Skipped checks never change the
    /// outcome, but a state we do not recognise leaves the result unknown rather than passing.
    public var status: CheckStatus {
        if isEmpty { return .unknown }
        if failed > 0 { return .failing }
        if cancelled > 0 { return .cancelled }
        if pending > 0 { return .pending }
        return unrecognized > 0 ? .unknown : .passing
    }

    /// Non-empty segments in bar order.
    public var segments: [Segment] {
        let t = Double(total)
        guard t > 0 else { return [] }
        return Kind.allCases.compactMap { kind in
            let n = count(of: kind)
            return n > 0 ? Segment(kind: kind, count: n, fraction: Double(n) / t) : nil
        }
    }

    /// Where one segment sits on a bar `width` points wide.
    public struct SegmentFrame: Equatable, Sendable {
        public var kind: Kind
        public var x: Double
        public var width: Double
    }

    /// Lays the segments out left to right with `gap` between them. Widths are proportional, except that a
    /// non-empty segment is never narrower than `minSegment`: the room comes from the wider segments, so one
    /// failing check among 34 stays visible. If the bar is too narrow for that, every segment gets an equal share.
    public func layout(width: Double, gap: Double = 1.5, minSegment: Double = 3) -> [SegmentFrame] {
        let segs = segments
        guard !segs.isEmpty, width > 0 else { return [] }
        let usable = max(0, width - gap * Double(segs.count - 1))
        var w = segs.map { usable * $0.fraction }
        let small = w.indices.filter { w[$0] < minSegment }
        if !small.isEmpty {
            let big = w.indices.filter { w[$0] >= minSegment }
            let deficit = small.reduce(0) { $0 + (minSegment - w[$1]) }
            let spare = big.reduce(0) { $0 + (w[$1] - minSegment) }
            if !big.isEmpty, spare >= deficit, spare > 0 {
                for i in big { w[i] -= (w[i] - minSegment) * deficit / spare }
                for i in small { w[i] = minSegment }
            } else {
                w = Array(repeating: usable / Double(segs.count), count: segs.count)
            }
        }
        var x = 0.0
        return zip(segs, w).map { seg, width in
            defer { x += width + gap }
            return SegmentFrame(kind: seg.kind, x: x, width: width)
        }
    }

    /// "30 passed, 2 failed, 2 skipped", for tooltips and VoiceOver.
    public var summary: String {
        segments.map { "\($0.count) \($0.kind.label)" }.joined(separator: ", ")
    }

    // MARK: Building

    mutating func add(_ kind: Kind, _ n: Int) {
        guard n > 0 else { return }
        switch kind {
        case .passed: passed += n
        case .failed: failed += n
        case .skipped: skipped += n
        case .cancelled: cancelled += n
        case .pending: pending += n
        }
    }

    static let knownCheckRunStates: Set<String> = [
        "SUCCESS", "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "CANCELLED",
        "IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED", "SKIPPED", "NEUTRAL", "STALE", "COMPLETED",
    ]
    static let knownStatusStates: Set<String> = ["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED"]

    /// GraphQL `CheckRunState`. A state we do not recognise (GitHub adds some over time) lands in `skipped`,
    /// which draws gray, so it can never be mistaken for a pass.
    public static func kind(checkRunState state: String) -> Kind {
        switch state {
        case "SUCCESS": .passed
        case "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED": .failed
        case "CANCELLED": .cancelled
        case "IN_PROGRESS", "QUEUED", "PENDING", "WAITING", "REQUESTED": .pending
        default: .skipped  // SKIPPED, NEUTRAL, STALE, COMPLETED and anything new
        }
    }

    /// GraphQL `StatusState`, for commit statuses reported by external CI.
    public static func kind(statusState state: String) -> Kind {
        switch state {
        case "SUCCESS": .passed
        case "FAILURE", "ERROR": .failed
        case "PENDING", "EXPECTED": .pending
        default: .skipped
        }
    }

    public struct StateCount: Sendable, Equatable {
        public var state: String
        public var count: Int
        public init(state: String, count: Int) { self.state = state; self.count = count }
    }

    /// From GitHub's per-state totals (`checkRunCountsByState` and `statusContextCountsByState`).
    public init(checkRuns: [StateCount], statuses: [StateCount]) {
        self.init()
        for c in checkRuns {
            add(Self.kind(checkRunState: c.state), c.count)
            if !Self.knownCheckRunStates.contains(c.state), c.count > 0 { unrecognized += c.count }
        }
        for c in statuses {
            add(Self.kind(statusState: c.state), c.count)
            if !Self.knownStatusStates.contains(c.state), c.count > 0 { unrecognized += c.count }
        }
    }

    /// Fallback when GitHub sent no totals: derive the breakdown from the checks we have.
    public init(checks: [CheckRun]) {
        self.init()
        for check in checks {
            switch check.status {
            case .passing: add(.passed, 1)
            case .failing: add(.failed, 1)
            case .cancelled: add(.cancelled, 1)
            case .pending: add(.pending, 1)
            case .skipped: add(.skipped, 1)
            case .unknown: add(.skipped, 1); unrecognized += 1
            }
        }
    }
}
