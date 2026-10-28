import Foundation

/// A parsed filter query: free text plus GitHub-style `key:value` tokens.
///
///     fix login author:alice -author:dependabot[bot] label:"good first issue" is:draft checks:failing
///
/// Free text terms must all match (title, author, head branch or a label). For tokens, values of the same key are
/// alternatives (`author:a author:b` is a OR b), a leading `-` excludes, and different keys must all hold.
public struct PRFilter: Sendable, Equatable {
    public enum Key: String, Sendable, CaseIterable {
        case author, label, reviewer, base, branch, repo, review, checks, `is`
    }

    public struct Clause: Sendable, Equatable {
        public var key: Key
        public var value: String
        public var negated: Bool
    }

    public private(set) var terms: [String] = []
    public private(set) var clauses: [Clause] = []

    public var isEmpty: Bool { terms.isEmpty && clauses.isEmpty }

    public static func parse(_ query: String) -> PRFilter {
        var f = PRFilter()
        for raw in FilterQuery.tokens(query) {
            var body = Substring(raw)
            let negated = body.hasPrefix("-")
            if negated { body = body.dropFirst() }
            if let colon = body.firstIndex(of: ":"),
                let key = Key(rawValue: body[..<colon].lowercased())
            {
                let value = FilterQuery.unquote(String(body[body.index(after: colon)...]))
                if !value.isEmpty {
                    f.clauses.append(Clause(key: key, value: value, negated: negated))
                    continue
                }
            }
            let term = FilterQuery.unquote(raw).lowercased()
            if !term.isEmpty { f.terms.append(term) }
        }
        return f
    }

    /// `me` resolves `author:@me` and `reviewer:@me`. `reviewer:@me` means a request addressed to the user, not one
    /// to a team they belong to; teams are matched as `reviewer:org/team`.
    public func matches(_ pr: PR, me: String? = nil) -> Bool {
        for term in terms {
            let hit =
                pr.title.lowercased().contains(term) || pr.author.lowercased().contains(term)
                || pr.headRef.lowercased().contains(term) || pr.labels.contains { $0.name.lowercased().contains(term) }
            if !hit { return false }
        }
        for key in Key.allCases {
            let mine = clauses.filter { $0.key == key }
            if mine.isEmpty { continue }
            let positive = mine.filter { !$0.negated }, negative = mine.filter(\.negated)
            // A PR whose labels or reviewers were cut off may hold the match, so it is kept rather than hidden.
            if !positive.isEmpty, !positive.contains(where: { Self.test($0, pr, me) || Self.mayBeBeyondLoaded($0, pr) }) { return false }
            if negative.contains(where: { Self.test($0, pr, me) }) { return false }
        }
        return true
    }

    static func mayBeBeyondLoaded(_ c: Clause, _ pr: PR) -> Bool {
        switch c.key {
        case .label: pr.labelsTruncated
        case .reviewer: pr.reviewersTruncated
        default: false
        }
    }

    static func test(_ c: Clause, _ pr: PR, _ me: String?) -> Bool {
        let v = c.value.lowercased()
        func eq(_ s: String) -> Bool { s.lowercased() == v }
        func resolved() -> String { v == "@me" ? (me ?? "").lowercased() : v }
        switch c.key {
        case .author: return pr.author.lowercased() == resolved()
        case .reviewer:
            // `org/team` names a team; anything else is a user, and `@me` is only ever a direct request.
            if v.contains("/") { return pr.requestedTeams.contains { $0.fullName.lowercased() == v } }
            return pr.requestedReviewers.contains { $0.lowercased() == resolved() }
        case .label: return pr.labels.contains { eq($0.name) }
        case .base: return eq(pr.baseRef)
        case .branch: return pr.headRef.lowercased().contains(v)
        case .repo: return eq(pr.repo.name) || eq(pr.repo.fullName)
        case .review:
            switch v {
            case "approved": return pr.reviewStatus == .approved
            case "changes", "changes_requested": return pr.reviewStatus == .changesRequested
            case "pending", "required": return pr.reviewStatus == .pending
            case "none": return pr.reviewStatus == .unknown
            default: return false
            }
        case .checks:
            switch v {
            case "passing", "success": return pr.checkSummary == .passing
            case "failing", "failed": return pr.checkSummary == .failing || pr.checkSummary == .cancelled
            case "pending": return pr.checkSummary == .pending
            case "none": return pr.checkSummary == .unknown
            default: return false
            }
        case .is:
            switch v {
            case "draft": return pr.isDraft
            case "ready": return !pr.isDraft
            case "bot": return pr.isBot
            case "open": return pr.isOpen
            case "closed": return !pr.isOpen
            case "approved": return pr.reviewStatus == .approved
            case "conflicts", "dirty": return pr.mergeable == .dirty
            case "behind": return pr.mergeable == .behind
            case "blocked": return pr.mergeable == .blocked
            case "automerge": return pr.autoMerge
            default: return false
            }
        }
    }
}

/// String-level helpers so UI controls can edit the query text directly.
public enum FilterQuery {
    /// Splits on whitespace outside double quotes. Raw tokens keep their quotes.
    public static func tokens(_ query: String) -> [String] {
        var out: [String] = [], current = "", inQuotes = false
        for ch in query {
            if ch == "\"" {
                inQuotes.toggle(); current.append(ch)
            } else if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") { t.removeFirst() }
        if t.hasSuffix("\"") { t.removeLast() }
        return t
    }

    /// `author:alice`, `label:"good first issue"`, `-is:bot`.
    public static func token(_ key: PRFilter.Key, _ value: String, negated: Bool = false) -> String {
        let v = value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
        return (negated ? "-" : "") + "\(key.rawValue):\(v)"
    }

    public static func contains(_ token: String, in query: String) -> Bool {
        tokens(query).contains { $0.caseInsensitiveCompare(token) == .orderedSame }
    }

    /// Adds the token, or removes it if it is already there.
    public static func toggling(_ token: String, in query: String) -> String {
        var all = tokens(query)
        if let i = all.firstIndex(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
            all.remove(at: i)
        } else {
            all.append(token)
        }
        return all.joined(separator: " ")
    }

    /// Drops every `key:` token, keeping free text and other keys.
    public static func removingAll(_ key: PRFilter.Key, from query: String) -> String {
        tokens(query).filter { raw in
            let body = raw.hasPrefix("-") ? String(raw.dropFirst()) : raw
            return !(body.lowercased().hasPrefix(key.rawValue + ":"))
        }.joined(separator: " ")
    }
}
