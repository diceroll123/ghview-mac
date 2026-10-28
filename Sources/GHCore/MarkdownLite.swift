import Foundation

public enum MarkdownBlock: Hashable, Sendable {
    case text(String)  // inline markdown, safe for AttributedString(markdown:)
    case code(String)
    case rule  // horizontal rule: ---, ***, ___
}

/// Turns GitHub-flavored comment bodies into blocks a SwiftUI view can render without a full markdown engine:
/// fenced code stays verbatim, common HTML (dependabot descriptions) becomes markdown, headings become bold.
public enum MarkdownLite {
    public static func blocks(_ raw: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var text: [String] = [], code: [String] = []
        var open: (char: Character, length: Int)?

        func flushText() {
            let joined = clean(text.joined(separator: "\n"))
            if !joined.isEmpty { blocks.append(.text(joined)) }
            text = []
        }
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let current = open {
                // Only a fence of the same character, at least as long, and with nothing after it closes the block.
                if let f = fence(line), f.char == current.char, f.length >= current.length, f.info.isEmpty {
                    blocks.append(.code(code.joined(separator: "\n"))); code = []; open = nil
                } else {
                    code.append(String(line))
                }
            } else if let f = fence(line) {
                flushText()
                open = (f.char, f.length)
            } else if isRule(line) {
                flushText(); blocks.append(.rule)
            } else {
                text.append(String(line))
            }
        }
        if open != nil { blocks.append(.code(code.joined(separator: "\n"))) }  // unterminated fence
        flushText()
        return blocks
    }

    /// A code fence line: three or more backticks or tildes, then an optional info string. A backtick fence's
    /// info string cannot contain a backtick (that would be an inline code span).
    static func fence(_ line: Substring) -> (char: Character, length: Int, info: String)? {
        let t = line.drop { $0 == " " || $0 == "\t" }
        guard let c = t.first, c == "`" || c == "~" else { return nil }
        let length = t.prefix { $0 == c }.count
        guard length >= 3 else { return nil }
        let info = t.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        return (c, length, info)
    }

    static func isRule(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && (t.allSatisfy { $0 == "-" } || t.allSatisfy { $0 == "*" } || t.allSatisfy { $0 == "_" })
    }

    /// `<a href>` becomes a markdown link. Images inside collapse to their alt text, and whitespace in the label
    /// is squeezed so a badge-style link never renders as a tall blank gap.
    static func convertLinks(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<a\s+[^>]*?href="([^"]*)"[^>]*>([\s\S]*?)</a>"#) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: out), let u = Range(m.range(at: 1), in: s), let l = Range(m.range(at: 2), in: s) else {
                continue
            }
            let url = String(s[u])
            let label = String(s[l]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            out.replaceSubrange(whole, with: label.isEmpty ? "<\(url)>" : "[\(label)](\(url))")
        }
        return out
    }

    // MARK: Code spans

    private static let spanOpen: Character = "\u{E000}", spanClose: Character = "\u{E001}"

    /// Pulls inline code out of `s` (CommonMark rules: a run of n backticks closes at the next run of exactly n;
    /// an unmatched run is literal) and leaves numbered placeholders, so nothing below can touch their contents.
    static func protectCodeSpans(_ s: String, into spans: inout [String]) -> String {
        let chars = Array(s)
        var out = "", i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "`" { out.append(c); out.append("`"); i += 2; continue }
            guard c == "`" else { out.append(c); i += 1; continue }
            var run = 0
            while i + run < chars.count, chars[i + run] == "`" { run += 1 }
            var j = i + run, closed: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    var r = 0
                    while j + r < chars.count, chars[j + r] == "`" { r += 1 }
                    if r == run { closed = j; break }
                    j += r
                } else {
                    j += 1
                }
            }
            if let end = closed {
                spans.append(String(chars[i..<(end + run)]))
                out.append("\(spanOpen)\(spans.count - 1)\(spanClose)")
                i = end + run
            } else {
                out.append(String(repeating: "`", count: run))  // no closing run: literal backticks
                i += run
            }
        }
        return out
    }

    static func restoreCodeSpans(_ s: String, from spans: [String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "\(spanOpen)(\\d+)\(spanClose)") else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: out), let n = Range(m.range(at: 1), in: s), let idx = Int(s[n]),
                spans.indices.contains(idx)
            else { continue }
            out.replaceSubrange(whole, with: spans[idx])
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        var t = s
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return t
    }

    static func clean(_ s: String) -> String {
        var spans: [String] = []
        // Backtick spans and `<code>` elements are set aside first: their contents are literal, and the HTML
        // clean-up below would otherwise eat things like the `<String>` in `Array<String>`.
        var t = protectCodeSpans(
            s.replacingOccurrences(of: String(spanOpen), with: "").replacingOccurrences(of: String(spanClose), with: ""), into: &spans)
        if let re = try? NSRegularExpression(pattern: #"<code>([\s\S]*?)</code>"#) {
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let whole = Range(m.range, in: t), let inner = Range(m.range(at: 1), in: t) else { continue }
                let body = decodeEntities(String(t[inner]))
                let ticks = String(repeating: "`", count: (body.longestBacktickRun) + 1)
                let pad = body.hasPrefix("`") || body.hasSuffix("`") ? " " : ""
                spans.append("\(ticks)\(pad)\(body)\(pad)\(ticks)")
                t.replaceSubrange(whole, with: "\(spanOpen)\(spans.count - 1)\(spanClose)")
            }
        }
        let pre: [(String, String)] = [
            (#"<!--[\s\S]*?-->"#, ""),
            (#"<source\b[^>]*>"#, ""),
            (#"</?picture[^>]*>"#, ""),
            (#"<img\b[^>]*?alt="([^"]*)"[^>]*>"#, "$1"),
        ]
        for (pattern, template) in pre { t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        t = convertLinks(t)
        let rules: [(String, String)] = [
            (#"<summary[^>]*>([\s\S]*?)</summary>"#, "**$1**\n"),
            (#"<br\s*/?>"#, "\n"),
            (#"<li[^>]*>"#, "- "),
            (#"</(li|p|ul|ol|details|blockquote|h[1-6])>"#, "\n"),
            (#"</?[A-Za-z][A-Za-z0-9]*(\s[^>]*)?/?>"#, ""),
            (#"(?m)^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$"#, "**$1**"),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return restoreCodeSpans(t, from: spans).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// The longest run of consecutive backticks, so a code span can be wrapped in a longer one.
    var longestBacktickRun: Int {
        var best = 0, run = 0
        for c in self { run = c == "`" ? run + 1 : 0; best = Swift.max(best, run) }
        return best
    }
}
