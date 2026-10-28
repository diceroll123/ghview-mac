import Foundation

public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case context, added, removed, note }
    public let id: Int  // unique within its file
    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String
}

public struct DiffHunk: Hashable, Sendable, Identifiable {
    public var id: Int
    public var header: String  // the raw "@@ -a,b +c,d @@ section" line
    public var section: String  // trailing function/section context, if any
    public var lines: [DiffLine]
}

public struct DiffFile: Hashable, Sendable, Identifiable {
    public enum Status: Sendable { case modified, added, deleted, renamed, copied }
    public var id: String { oldPath + "->" + newPath }
    public var oldPath: String
    public var newPath: String
    public var status: Status
    public var hunks: [DiffHunk]
    public var additions: Int
    public var deletions: Int
    /// Binary content, whatever else happened to the file (a new binary file is `.added` and binary).
    public var isBinary = false
    /// "100644 -> 100755" when only (or also) the file mode changed.
    public var modeChange: String?

    public var displayPath: String {
        switch status {
        case .renamed, .copied: "\(oldPath) -> \(newPath)"
        case .deleted: oldPath
        default: newPath
        }
    }
    public var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }
}

/// Parses `git diff` / `gh pr diff` unified output.
public enum DiffParser {
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var hunk: DiffHunk?
        var oldNo = 0, newNo = 0, lineId = 0
        var oldMode: String?, newMode: String?
        func modeChange(_ old: String?, _ new: String?) -> String? {
            guard let old, let new else { return nil }
            return "\(old) -> \(new)"
        }

        func flushHunk() {
            if let h = hunk { current?.hunks.append(h) }
            hunk = nil
        }
        func flushFile() {
            flushHunk()
            if let f = current { files.append(f) }
            current = nil
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flushFile()
                let (a, b) = paths(fromHeader: String(line.dropFirst("diff --git ".count)))
                current = DiffFile(oldPath: a, newPath: b, status: .modified, hunks: [], additions: 0, deletions: 0)
                lineId = 0
                oldMode = nil; newMode = nil
                continue
            }
            guard current != nil else { continue }

            if hunk == nil {
                // File header lines, before the first hunk.
                if line.hasPrefix("new file mode") {
                    current!.status = .added
                } else if line.hasPrefix("deleted file mode") {
                    current!.status = .deleted
                } else if line.hasPrefix("old mode ") {
                    oldMode = String(line.dropFirst(9)); current!.modeChange = modeChange(oldMode, newMode)
                } else if line.hasPrefix("new mode ") {
                    newMode = String(line.dropFirst(9)); current!.modeChange = modeChange(oldMode, newMode)
                } else if line.hasPrefix("rename from ") {
                    current!.status = .renamed; current!.oldPath = unquote(String(line.dropFirst(12)))
                } else if line.hasPrefix("rename to ") {
                    current!.newPath = unquote(String(line.dropFirst(10)))
                } else if line.hasPrefix("copy from ") {
                    current!.status = .copied; current!.oldPath = unquote(String(line.dropFirst(10)))
                } else if line.hasPrefix("copy to ") {
                    current!.newPath = unquote(String(line.dropFirst(8)))
                } else if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") {
                    current!.isBinary = true
                } else if line.hasPrefix("--- ") {
                    if let p = stripPrefix(String(line.dropFirst(4))) { current!.oldPath = p }
                } else if line.hasPrefix("+++ ") {
                    if let p = stripPrefix(String(line.dropFirst(4))) { current!.newPath = p }
                }
            }

            if line.hasPrefix("@@") {
                flushHunk()
                let (o, n, section) = hunkHeader(line)
                oldNo = o; newNo = n
                hunk = DiffHunk(id: (current?.hunks.count ?? 0), header: line, section: section, lines: [])
                continue
            }
            guard hunk != nil else { continue }

            lineId += 1
            switch line.first {
            case "+":
                hunk!.lines.append(DiffLine(id: lineId, kind: .added, oldNumber: nil, newNumber: newNo, text: String(line.dropFirst())))
                newNo += 1; current!.additions += 1
            case "-":
                hunk!.lines.append(DiffLine(id: lineId, kind: .removed, oldNumber: oldNo, newNumber: nil, text: String(line.dropFirst())))
                oldNo += 1; current!.deletions += 1
            case "\\":
                hunk!.lines.append(DiffLine(id: lineId, kind: .note, oldNumber: nil, newNumber: nil, text: String(line.dropFirst(2))))
            case " ":
                hunk!.lines.append(DiffLine(id: lineId, kind: .context, oldNumber: oldNo, newNumber: newNo, text: String(line.dropFirst())))
                oldNo += 1; newNo += 1
            default:
                // An empty line inside a hunk is a context line whose leading space was trimmed.
                if line.isEmpty {
                    hunk!.lines.append(DiffLine(id: lineId, kind: .context, oldNumber: oldNo, newNumber: newNo, text: ""))
                    oldNo += 1; newNo += 1
                }
            }
        }
        flushFile()
        // Trailing blank line from the final newline is not a real context line.
        return files.map { f in
            var f = f
            if var last = f.hunks.last, let l = last.lines.last, l.kind == .context, l.text.isEmpty, text.hasSuffix("\n"),
                f.id == files.last?.id
            {
                last.lines.removeLast()
                f.hunks[f.hunks.count - 1] = last
            }
            return f
        }
    }

    /// Decodes git's C-style quoting: `"foo\\tbar\\303\\251.swift"` -> `foo<tab>baré.swift`. Git quotes a path when it
    /// holds a tab, newline, quote, backslash or non-ASCII bytes (written as octal escapes of the UTF-8 bytes).
    /// Anything not wrapped in quotes is returned as it is.
    static func unquote(_ s: String) -> String {
        guard let (decoded, rest) = readQuoted(Substring(s)), rest.isEmpty else { return s }
        return decoded
    }

    /// Reads one quoted path from the start of `s`; returns it decoded plus whatever follows the closing quote.
    static func readQuoted(_ s: Substring) -> (String, Substring)? {
        guard s.first == "\"" else { return nil }
        var bytes: [UInt8] = []
        var iterator = s.utf8.dropFirst().makeIterator()
        var consumed = 1
        while let b = iterator.next() {
            consumed += 1
            if b == UInt8(ascii: "\"") {
                let rest = Substring(String(decoding: Array(s.utf8.dropFirst(consumed)), as: UTF8.self))
                return (String(decoding: bytes, as: UTF8.self), rest)
            }
            guard b == UInt8(ascii: "\\") else { bytes.append(b); continue }
            guard let e = iterator.next() else { return nil }
            consumed += 1
            switch e {
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Up to three octal digits make one byte.
                var value = Int(e - UInt8(ascii: "0"))
                var digits = 1
                var peek = iterator
                while digits < 3, let d = peek.next(), (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(d) {
                    value = value * 8 + Int(d - UInt8(ascii: "0"))
                    iterator = peek
                    consumed += 1
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(e)  // \\ and \" and anything else stand for themselves
            }
        }
        return nil  // no closing quote
    }

    /// "a/foo bar.txt b/foo bar.txt" -> ("foo bar.txt", "foo bar.txt"). Either side may be quoted.
    /// Unquoted identical paths are unambiguous even with spaces; otherwise it prefers the middle " b/" split.
    static func paths(fromHeader h: String) -> (String, String) {
        func strip(_ p: String) -> String { p.hasPrefix("a/") || p.hasPrefix("b/") ? String(p.dropFirst(2)) : p }
        if h.hasPrefix("\""), let (first, rest) = readQuoted(Substring(h)) {
            let tail = rest.drop { $0 == " " }
            if let (second, _) = readQuoted(tail) { return (strip(first), strip(second)) }
            return (strip(first), strip(String(tail)))
        }
        if let r = h.range(of: " \"b/"), let (second, _) = readQuoted(h[h.index(after: r.lowerBound)...]) {
            return (strip(String(h[..<r.lowerBound])), strip(second))
        }
        guard h.hasPrefix("a/") else { return (h, h) }
        let body = String(h.dropFirst(2))
        let half = (body.count - 3) / 2
        if body.count % 2 == 1, half > 0 {
            let a = String(body.prefix(half))
            if body == a + " b/" + a { return (a, a) }
        }
        if let r = body.range(of: " b/") { return (String(body[..<r.lowerBound]), String(body[r.upperBound...])) }
        return (body, body)
    }

    static func stripPrefix(_ p: String) -> String? {
        if p == "/dev/null" { return nil }
        // A quoted path is complete in itself; an unquoted one may carry a trailing tab that git adds after
        // names containing spaces.
        let path = p.hasPrefix("\"") ? unquote(p) : (p.split(separator: "\t").first.map(String.init) ?? p)
        return (path.hasPrefix("a/") || path.hasPrefix("b/")) ? String(path.dropFirst(2)) : path
    }

    /// "@@ -12,5 +14,7 @@ func foo()" -> (12, 14, "func foo()")
    static func hunkHeader(_ line: String) -> (Int, Int, String) {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        func start(_ s: Substring) -> Int {
            Int(s.dropFirst().split(separator: ",").first ?? "") ?? 1
        }
        guard parts.count >= 3 else { return (1, 1, "") }
        let section = parts.count == 5 ? String(parts[4]) : ""
        return (start(parts[1]), start(parts[2]), section)
    }
}

public enum DiffFetcher {
    /// What a diff is a diff of: the PR, the base branch it is compared against, and the exact head commit.
    /// Anything cached under this identity can only ever hold that comparison.
    public static func identity(_ pr: PR) -> String {
        "\(pr.repo.fullName)#\(pr.number)@\(pr.headSha)...\(pr.baseRef)"
    }

    /// The API path of the comparison, pinned to `pr.headSha` rather than to whatever the PR's head is now.
    static func comparePath(_ pr: PR) -> String {
        let base = pr.baseRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pr.baseRef
        return "repos/\(pr.repo.fullName)/compare/\(base)...\(pr.headSha)"
    }

    public struct Result: Sendable, Equatable {
        public var files: [DiffFile]
        /// True when the pinned comparison was not available and the PR's current diff was used instead, which
        /// means the list is probably out of date.
        public var usedCurrentDiff: Bool
    }

    /// Fetches the three-dot diff from the base branch to the head commit the PR had when it was listed, so a
    /// push (or a retarget) after that cannot land in the diff stored under that commit's key. If that comparison
    /// cannot be had (a commit that was force-pushed away, a renamed base branch), the PR's current diff is used
    /// and the result says so, rather than showing nothing.
    public static func fetchResult(_ pr: PR, gh: any GhRunner) async throws -> Result {
        do {
            let data = try await gh.run(["api", "-H", "Accept: application/vnd.github.diff", comparePath(pr)])
            return Result(files: DiffParser.parse(String(decoding: data, as: UTF8.self)), usedCurrentDiff: false)
        } catch let pinned as GhError where pinned.status != 124 {
            do {
                let data = try await gh.run(["pr", "diff", String(pr.number), "-R", pr.repo.fullName, "--color=never"])
                return Result(files: DiffParser.parse(String(decoding: data, as: UTF8.self)), usedCurrentDiff: true)
            } catch let current as GhError {
                // Report both, since either one could be the useful clue.
                throw GhError(
                    args: current.args, status: current.status,
                    stderr:
                        "\(current.stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n(the pinned comparison also failed: \(pinned.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))"
                )
            }
        }
    }

    public static func fetch(_ pr: PR, gh: any GhRunner) async throws -> [DiffFile] {
        try await fetchResult(pr, gh: gh).files
    }
}
