import SwiftUI
import GHCore

extension CheckCounts.Kind {
    var color: Color {
        switch self {
        case .passed: .green
        case .failed: .red
        case .skipped: .gray.opacity(0.4)
        case .cancelled: .gray
        case .pending: .orange
        }
    }
}

/// A segmented progress bar for a PR's checks. Finished checks fill from the left (green passed, red failed,
/// gray skipped or cancelled); checks still running are an amber striped tail on the right.
struct ChecksBar: View {
    let counts: CheckCounts
    var height: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The clock only runs while something is pending, and not at all with Reduce Motion.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: counts.pending == 0 || reduceMotion)) { context in
            Canvas { gc, size in
                let frames = counts.layout(width: size.width)
                let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                gc.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2))
                for f in frames {
                    let rect = CGRect(x: f.x, y: 0, width: f.width, height: size.height)
                    if f.kind == .pending {
                        gc.fill(Path(rect), with: .color(CheckCounts.Kind.pending.color.opacity(0.3)))
                        gc.drawLayer { layer in
                            layer.clip(to: Path(rect))
                            Self.stripes(in: rect, phase: phase, into: &layer)
                        }
                    } else {
                        gc.fill(Path(rect), with: .color(f.kind.color))
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Checks")
        .accessibilityValue(counts.summary)
        .help(counts.summary)
    }

    /// Diagonal bands that drift to the right, so a running check reads as work in progress. Shared with
    /// `BatchProgressBar`, which draws the same "still working" tail for a running batch action.
    static func stripes(in rect: CGRect, phase: Double, into layer: inout GraphicsContext) {
        let period: CGFloat = 10, band: CGFloat = 5, speed: Double = 14
        let offset = CGFloat((phase * speed).truncatingRemainder(dividingBy: Double(period)))
        let slant = rect.height
        var path = Path()
        var x = rect.minX - slant - period + offset
        while x < rect.maxX + slant {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + band, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + band + slant, y: rect.minY))
            path.addLine(to: CGPoint(x: x + slant, y: rect.minY))
            path.closeSubpath()
            x += period
        }
        layer.fill(path, with: .color(CheckCounts.Kind.pending.color))
    }
}

/// Colored dots with a count for every kind that is present.
struct ChecksLegend: View {
    let counts: CheckCounts

    var body: some View {
        FlowLayout(spacing: 10) {
            ForEach(counts.segments, id: \.kind) { seg in
                HStack(spacing: 4) {
                    Circle().fill(seg.kind.color).frame(width: 7, height: 7)
                    Text(verbatim: "\(seg.count) \(seg.kind.label)").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .accessibilityHidden(true)  // the bar already reads the same summary aloud
    }
}
