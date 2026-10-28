import Foundation
import GHCore

#if DEBUG
    /// Fake, offline data for screenshots: no `gh` call is ever made. Uses the real `microsoft` organization and a
    /// few of its well-known public repositories, so the sidebar's avatar is a genuine, recognizable image; PR
    /// authors are GitHub's own `octocat` mascot account and well-known bot accounts, not real individuals.
    enum DemoFixtures {
        static let orgLogin = "microsoft"

        /// `openPRs` is derived from `prs` below rather than stated separately, so the two can never drift apart.
        private static func repo(
            _ name: String, language: String, stars: Int, releaseTag: String?,
            releaseDaysAgo: Int?, pushedHoursAgo: Double
        ) -> RepoInfo {
            RepoInfo(
                id: RepoId(owner: orgLogin, name: name),
                language: language,
                pushedAt: Date().addingTimeInterval(-pushedHoursAgo * 3600),
                stars: stars,
                openPRs: prs.filter { $0.repo.name == name }.count,
                isPrivate: false,
                releaseTag: releaseTag,
                releaseDate: releaseDaysAgo.map { Date().addingTimeInterval(-Double($0) * 86400) }
            )
        }

        static let repos: [RepoInfo] = [
            repo("vscode", language: "TypeScript", stars: 168_000, releaseTag: "1.95.0", releaseDaysAgo: 4, pushedHoursAgo: 2),
            repo("TypeScript", language: "TypeScript", stars: 102_000, releaseTag: "5.7.0", releaseDaysAgo: 10, pushedHoursAgo: 6),
            repo("playwright", language: "TypeScript", stars: 69_000, releaseTag: "1.49.0", releaseDaysAgo: 2, pushedHoursAgo: 1),
            repo("terminal", language: "C++", stars: 96_000, releaseTag: "1.21.3033.0", releaseDaysAgo: 20, pushedHoursAgo: 30),
        ]

        private static func pr(
            _ repoName: String, _ number: Int, title: String, author: String, draft: Bool = false,
            hoursAgo: Double, additions: Int, deletions: Int, comments: Int = 0,
            reviewStatus: ReviewStatus = .unknown, mergeable: MergeableState = .clean,
            autoMerge: Bool = false, labels: [PRLabel] = [], checkCounts: CheckCounts,
            checkSummary: CheckStatus, requestedReviewers: [String] = []
        ) -> PR {
            let repo = RepoId(owner: orgLogin, name: repoName)
            return PR(
                id: PrId(repo: repo, number: number), title: title, author: author, isDraft: draft, isOpen: true,
                createdAt: Date().addingTimeInterval(-hoursAgo * 3600 - 86400), updatedAt: Date().addingTimeInterval(-hoursAgo * 3600),
                url: repo.pullRequestsURL.absoluteString, headRef: "feature/\(number)", baseRef: "main",
                headSha: String(format: "%040x", number * 0xABCDEF), additions: additions, deletions: deletions,
                comments: comments, autoMerge: autoMerge, reviewStatus: reviewStatus, viewerApproved: false,
                mergeable: mergeable, requestedReviewers: requestedReviewers, labels: labels, checks: [],
                checkSummary: checkSummary, checkCounts: checkCounts)
        }

        static let prs: [PR] = [
            pr(
                "vscode", 231_045, title: "Fix flaky terminal resize test on Windows", author: "octocat",
                hoursAgo: 2, additions: 42, deletions: 11, comments: 3, reviewStatus: .approved,
                labels: [PRLabel(name: "bug", color: "d73a4a")], checkCounts: CheckCounts(passed: 12), checkSummary: .passing),
            pr(
                "vscode", 231_050, title: "Add setting to control editor minimap font size", author: "octocat", draft: true,
                hoursAgo: 5, additions: 118, deletions: 4, checkCounts: CheckCounts(passed: 9, pending: 2), checkSummary: .pending,
                requestedReviewers: ["octocat"]),
            pr(
                "TypeScript", 60_321, title: "Narrow discriminated unions through optional chaining", author: "octocat",
                hoursAgo: 8, additions: 236, deletions: 58, comments: 14, reviewStatus: .changesRequested, mergeable: .dirty,
                labels: [PRLabel(name: "Fix Available", color: "0e8a16"), PRLabel(name: "Breaking Change", color: "e99695")],
                checkCounts: CheckCounts(passed: 20, failed: 1), checkSummary: .failing),
            pr(
                "TypeScript", 60_330, title: "Bump @types/node from 22.9.0 to 22.10.1", author: "dependabot[bot]",
                hoursAgo: 1, additions: 6, deletions: 6, autoMerge: true, checkCounts: CheckCounts(passed: 5), checkSummary: .passing),
            pr(
                "playwright", 33_812, title: "feat(webkit): support new network interception API", author: "octocat",
                hoursAgo: 12, additions: 310, deletions: 44, comments: 6, reviewStatus: .pending,
                checkCounts: CheckCounts(passed: 40, pending: 6), checkSummary: .pending, requestedReviewers: ["octocat"]),
            pr(
                "playwright", 33_820, title: "docs: clarify locator strictness in README", author: "github-actions[bot]",
                hoursAgo: 20, additions: 14, deletions: 9, checkCounts: CheckCounts(passed: 3), checkSummary: .passing),
            pr(
                "terminal", 18_204, title: "Respect Settings UI color scheme when system theme changes", author: "octocat",
                hoursAgo: 30, additions: 87, deletions: 20, comments: 2, reviewStatus: .approved,
                checkCounts: CheckCounts(passed: 15, cancelled: 1), checkSummary: .cancelled),
        ]

        static let counts: [String: SourceCounts] = [
            Source.org(orgLogin).id: SourceCounts(open: prs.count, reviewRequested: prs.filter { !$0.requestedReviewers.isEmpty }.count)
        ]

        static let rateLimit: RateLimit? = try? JSONDecoder().decode(
            RateLimit.self, from: Data(#"{"remaining":4821,"limit":5000,"cost":1,"resetAt":null,"used":179,"nodeCount":500}"#.utf8))
    }
#endif
