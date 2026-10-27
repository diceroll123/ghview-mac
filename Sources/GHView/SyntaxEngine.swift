import SwiftUI
import GHCore
import Highlightr

/// Owns the JavaScriptCore-backed highlighter. The actor keeps every call on one serial executor,
/// since a JSContext is not thread-safe, and keeps highlighting off the main thread.
actor SyntaxEngine {
    static let shared = SyntaxEngine()

    private let highlightr: Highlightr?
    private let supported: Set<String>
    private var currentTheme: String?
    private var cache: [String: [Int: AttributedString]] = [:]

    /// Files or lines beyond these limits stay plain: highlight.js gets slow on huge or minified input.
    private static let maxFileLines = 3000
    private static let maxLineLength = 1500

    init() {
        let h = Highlightr()
        highlightr = h
        supported = Set(h?.supportedLanguages() ?? [])
    }

    /// Returns colored text keyed by `DiffLine.id`. Lines it could not highlight are simply absent.
    func highlight(file: DiffFile, cacheKey: String, dark: Bool) -> [Int: AttributedString] {
        let key = "\(cacheKey)|\(file.id)|\(dark)"
        if let hit = cache[key] { return hit }
        guard let h = highlightr, file.lineCount <= Self.maxFileLines,
              let lang = LanguageDetector.language(forPath: file.status == .deleted ? file.oldPath : file.newPath),
              supported.contains(lang) else { return [:] }

        let theme = dark ? "github-dark" : "github"
        if currentTheme != theme { _ = h.setTheme(to: theme); currentTheme = theme }

        var result: [Int: AttributedString] = [:]
        for hunk in file.hunks {
            let (new, old) = hunk.sideStreams()
            // Old side first so context lines end up using the new side's tokens.
            if hunk.lines.contains(where: { $0.kind == .removed }) { apply(old, with: h, lang: lang, into: &result) }
            apply(new, with: h, lang: lang, into: &result)
        }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private func apply(_ stream: [(id: Int, text: String)], with h: Highlightr, lang: String,
                       into result: inout [Int: AttributedString]) {
        guard !stream.isEmpty, !stream.contains(where: { $0.text.count > Self.maxLineLength }),
              let colored = h.highlight(stream.map(\.text).joined(separator: "\n"), as: lang, fastRender: true) else { return }
        let lines = Self.split(colored)
        guard lines.count == stream.count else { return } // never misalign colors with lines
        for (entry, line) in zip(stream, lines) { result[entry.id] = line }
    }

    /// Splits a highlighted string into per-line AttributedStrings, keeping only foreground colors
    /// so the diff view's own monospaced font and sizing win.
    static func split(_ ns: NSAttributedString) -> [AttributedString] {
        var out: [AttributedString] = [AttributedString()]
        let whole = ns.string as NSString
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let color = (attrs[.foregroundColor] as? NSColor).map { Color(nsColor: $0) }
            let parts = whole.substring(with: range).split(separator: "\n", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                if i > 0 { out.append(AttributedString()) }
                guard !part.isEmpty else { continue }
                var piece = AttributedString(String(part))
                if let color { piece.foregroundColor = color }
                out[out.count - 1].append(piece)
            }
        }
        return out
    }
}
