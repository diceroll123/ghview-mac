import Foundation
import Testing
@testable import GHView

private func sources() throws -> [(name: String, text: String)] {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/GHView")
    return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
        .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
}

/// A once-uncommitted debugging hook could pick a repository, snapshot the window to a file and quit the app when
/// an environment variable was set. Nothing of that kind belongs in the shipped startup path.
@Test func theShippedAppHasNoCaptureOrSelfTerminateHooks() throws {
    let forbidden = ["GHVIEW_", "bitmapImageRepForCachingDisplay", "cacheDisplay(in", "NSApp.terminate",
                     "NSApplication.shared.terminate", "exit(0)"]
    for (name, text) in try sources() {
        // Only text outside `#if DEBUG ... #endif` counts.
        var depth = 0, release = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if DEBUG") { depth += 1; continue }
            if depth > 0, t.hasPrefix("#endif") { depth -= 1; continue }
            if depth == 0 { release += line + "\n" }
        }
        for needle in forbidden { #expect(!release.contains(needle), "\(name) contains \(needle) outside #if DEBUG") }
    }
}

@Test func theMeasuredTableMarginIsUsedOnlyWhenItIsPlausible() {
    #expect(PRRowSeparator.margin(tableWidth: 587, cellWidth: 555) == 16)             // the measured case
    #expect(PRRowSeparator.margin(tableWidth: 600, cellWidth: 600) == 0)               // a style with no inset
    #expect(PRRowSeparator.margin(tableWidth: 640, cellWidth: 560) == 40)
    #expect(PRRowSeparator.margin(tableWidth: 700, cellWidth: 400) == nil)             // half-laid-out: keep the old value
    #expect(PRRowSeparator.margin(tableWidth: 500, cellWidth: 560) == nil)             // a cell wider than its table
    #expect(PRRowSeparator.margin(tableWidth: 0, cellWidth: 100) == nil)
    #expect(PRRowSeparator.margin(tableWidth: 300, cellWidth: 0) == nil)
    #expect(PRRowSeparator.defaultMargin == 16)
}
