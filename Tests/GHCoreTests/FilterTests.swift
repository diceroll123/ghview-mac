import Foundation
import Testing
@testable import GHCore

private func pr(
    _ n: Int, author: String = "alice", title: String = "t", draft: Bool = false, labels: [String] = [],
    review: ReviewStatus = .unknown, checks: CheckStatus = .unknown, mergeable: MergeableState = .clean,
    head: String = "feat/x", base: String = "main", reviewers: [String] = [], auto: Bool = false
) -> PR {
    var p = samplePR(n, author: author, draft: draft, mergeable: mergeable, autoMerge: auto)
    p.title = title; p.labels = labels.map { PRLabel(name: $0, color: "fff") }
    p.reviewStatus = review; p.checkSummary = checks; p.headRef = head; p.baseRef = base; p.requestedReviewers = reviewers
    return p
}

@Test func tokenizerKeepsQuotes() {
    #expect(FilterQuery.tokens(#"fix  label:"good first issue" -is:bot"#) == ["fix", #"label:"good first issue""#, "-is:bot"])
    #expect(FilterQuery.tokens("   ").isEmpty)
    #expect(FilterQuery.token(.label, "good first issue") == #"label:"good first issue""#)
    #expect(FilterQuery.token(.is, "bot", negated: true) == "-is:bot")
}

@Test func freeTextMatchesTitleAuthorBranchLabelAndAllTermsMustHit() {
    let p = pr(1, author: "Alice", title: "Fix login crash", labels: ["Bug"], head: "hotfix/session")
    #expect(PRFilter.parse("login").matches(p))
    #expect(PRFilter.parse("alice").matches(p))
    #expect(PRFilter.parse("hotfix").matches(p))
    #expect(PRFilter.parse("bug").matches(p))
    #expect(PRFilter.parse("login crash").matches(p))
    #expect(!PRFilter.parse("login payments").matches(p))
    #expect(PRFilter.parse("").matches(p) && PRFilter.parse("  ").isEmpty)
}

@Test func sameKeyIsOrDifferentKeysAreAndNegationExcludes() {
    let a = pr(1, author: "alice", labels: ["bug"]), b = pr(2, author: "bob", labels: ["bug"]), c = pr(3, author: "cy", labels: ["docs"])
    let f = PRFilter.parse("author:alice author:bob")
    #expect([a, b, c].filter { f.matches($0) }.map(\.number) == [1, 2])
    let g = PRFilter.parse("author:alice author:bob label:bug -author:bob")
    #expect([a, b, c].filter { g.matches($0) }.map(\.number) == [1])
    #expect(PRFilter.parse("-author:alice").matches(b) && !PRFilter.parse("-author:alice").matches(a))
    #expect(PRFilter.parse("AUTHOR:ALICE").matches(a))  // keys and values are case-insensitive
}

@Test func meResolvesAndBotsAreRecognised() {
    let mine = pr(1, author: "steve"), bot = pr(2, author: "dependabot[bot]")
    #expect(PRFilter.parse("author:@me").matches(mine, me: "Steve"))
    #expect(!PRFilter.parse("author:@me").matches(mine, me: nil))  // unknown viewer matches nothing
    #expect(PRFilter.parse("is:bot").matches(bot) && !PRFilter.parse("is:bot").matches(mine))
    #expect(PRFilter.parse("-is:bot").matches(mine) && !PRFilter.parse("-is:bot").matches(bot))
    #expect(pr(3, author: "renovate").isBot && pr(4, author: "github-actions[bot]").isBot && !pr(5, author: "robot-fan").isBot)
}

@Test func statusKeys() {
    let p = pr(1, draft: true, review: .changesRequested, checks: .cancelled, mergeable: .dirty, auto: true)
    for q in ["is:draft", "-is:ready", "review:changes", "checks:failing", "is:conflicts", "is:automerge", "-checks:passing"] {
        #expect(PRFilter.parse(q).matches(p), "\(q)")
    }
    for q in ["is:ready", "review:approved", "checks:pending", "is:behind", "checks:none", "review:none"] {
        #expect(!PRFilter.parse(q).matches(p), "\(q)")
    }
    #expect(PRFilter.parse("checks:none review:none").matches(pr(2)))  // nothing reported, no review yet
}

@Test func otherKeysAndUnknownTokensFallBackToText() {
    let p = pr(1, title: "hello:world", head: "renovate/nextjs", base: "develop", reviewers: ["Zed"])
    #expect(PRFilter.parse("base:develop branch:nextjs reviewer:zed repo:r").matches(p))
    #expect(!PRFilter.parse("base:main").matches(p))
    #expect(PRFilter.parse("hello:world").matches(p))  // unknown key is plain text, so it still finds the title
    #expect(PRFilter.parse("author:").matches(pr(2, title: "has author: in it")))  // empty value is plain text too
    #expect(PRFilter.parse("-").isEmpty == false)
}

@Test func toggleAddsRemovesAndPreservesOtherText() {
    var q = "fix"
    q = FilterQuery.toggling("author:alice", in: q)
    #expect(q == "fix author:alice")
    q = FilterQuery.toggling("-is:bot", in: q)
    #expect(FilterQuery.contains("AUTHOR:alice", in: q) && FilterQuery.contains("-is:bot", in: q))
    q = FilterQuery.toggling("author:ALICE", in: q)
    #expect(q == "fix -is:bot")
    #expect(FilterQuery.removingAll(.is, from: "a is:draft -is:bot author:x") == "a author:x")
}

@Test func accountsBotDetection() {
    for bot in ["dependabot[bot]", "Renovate[bot]", "github-actions[bot]", "codspeed-hq[bot]", "copilot", "dependabot"] {
        #expect(Accounts.isBot(bot), "\(bot)")
    }
    for human in ["alice", "robot-fan", "bot", "diceroll123", "ghost"] {
        #expect(!Accounts.isBot(human), "\(human)")
    }
}

// MARK: reviewers and labels

@Test func teamsAndUsersWithTheSameNameAreDistinct() {
    var p = pr(1)
    p.requestedReviewers = ["alice"]
    p.requestedTeams = [ReviewTeam(org: "acme", slug: "core")]
    #expect(PRFilter.parse("reviewer:alice").matches(p))
    #expect(!PRFilter.parse("reviewer:core").matches(p))  // a team slug is not a user login
    #expect(PRFilter.parse("reviewer:acme/core").matches(p))
    #expect(!PRFilter.parse("reviewer:other/core").matches(p))

    var teamOnly = pr(2)
    teamOnly.requestedTeams = [ReviewTeam(org: "acme", slug: "me")]  // a team that happens to be called "me"
    #expect(!PRFilter.parse("reviewer:@me").matches(teamOnly, me: "me"))
    #expect(!PRFilter.parse("reviewer:me").matches(teamOnly, me: "me"))
}

@Test func truncatedLabelsAndReviewersAreNeverHiddenByAPositiveFilter() {
    var p = pr(1)
    p.labels = [PRLabel(name: "one", color: "ffffff")]
    p.labelTotal = 35  // 34 more than we carry
    #expect(p.labelsTruncated)
    #expect(PRFilter.parse("label:deep-in-the-list").matches(p))  // might be label 30
    #expect(PRFilter.parse("-label:deep-in-the-list").matches(p))  // a negation cannot exclude what we cannot see

    p.labelTotal = 1
    #expect(!p.labelsTruncated)
    #expect(!PRFilter.parse("label:deep-in-the-list").matches(p))

    var r = pr(2)
    r.requestedReviewers = ["a"]
    r.reviewRequestTotal = 40
    #expect(r.reviewersTruncated)
    #expect(PRFilter.parse("reviewer:@me").matches(r, me: "someone"))
}
