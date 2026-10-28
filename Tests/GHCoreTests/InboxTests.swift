import Foundation
import Testing
@testable import GHCore

private func pr(
    _ n: Int = 1, author: String = "me", draft: Bool = false, review: ReviewStatus = .pending,
    checks: CheckStatus = .passing, merge: MergeableState = .blocked, users: [String] = [], teams: [String] = [],
    checkCounts: CheckCounts = CheckCounts(passed: 3)
) -> PR {
    var p = samplePR(n, author: author, draft: draft, mergeable: merge)
    p.reviewStatus = review
    p.checkSummary = checks
    p.checkCounts = checkCounts
    p.requestedReviewers = users
    p.requestedTeams = teams.map { ReviewTeam(org: "acme", slug: $0) }
    return p
}

@Test func yourOwnPRsLandInExactlyOneSection() {
    #expect(InboxSection.classify(pr(draft: true), viewer: "me") == .yourDrafts)
    #expect(InboxSection.classify(pr(draft: true, review: .changesRequested, checks: .failing), viewer: "me") == .yourDrafts)

    // needs action: any one of changes requested, failing or cancelled checks, a conflict
    #expect(InboxSection.classify(pr(review: .changesRequested), viewer: "me") == .needsAction)
    #expect(InboxSection.classify(pr(review: .approved, checks: .failing, merge: .clean), viewer: "me") == .needsAction)
    #expect(InboxSection.classify(pr(checks: .cancelled), viewer: "me") == .needsAction)
    #expect(InboxSection.classify(pr(review: .approved, merge: .dirty), viewer: "me") == .needsAction)

    // ready: approved, checks fine, clean merge state
    #expect(InboxSection.classify(pr(review: .approved, merge: .clean), viewer: "me") == .readyToMerge)
    #expect(InboxSection.classify(pr(review: .approved, merge: .hasHooks), viewer: "me") == .readyToMerge)
    #expect(
        InboxSection.classify(pr(review: .approved, checks: .unknown, merge: .clean, checkCounts: CheckCounts()), viewer: "me")
            == .readyToMerge)  // no checks at all

    // everything else that is open and not a draft is waiting
    #expect(InboxSection.classify(pr(review: .pending, merge: .clean), viewer: "me") == .waiting)  // not approved yet
    #expect(InboxSection.classify(pr(review: .approved, checks: .pending, merge: .blocked), viewer: "me") == .waiting)
    #expect(InboxSection.classify(pr(review: .approved, merge: .behind), viewer: "me") == .waiting)  // behind alone is not action
    #expect(InboxSection.classify(pr(review: .approved, merge: .blocked), viewer: "me") == .waiting)
    #expect(InboxSection.classify(pr(review: .approved, checks: .unknown, merge: .clean), viewer: "me") == .waiting)  // unrecognized check state is not a pass
}

@Test func reviewRequestsSplitIntoYoursAndYourTeams() {
    #expect(InboxSection.classify(pr(author: "alice", users: ["me"]), viewer: "me") == .needsYourReview)
    #expect(InboxSection.classify(pr(author: "alice", users: ["ME", "bob"], teams: ["core"]), viewer: "me") == .needsYourReview)  // by name wins
    #expect(InboxSection.classify(pr(author: "alice", users: ["bob"], teams: ["core"]), viewer: "me") == .needsTeamsReview)
    #expect(InboxSection.classify(pr(author: "alice", teams: ["me"]), viewer: "me") == .needsTeamsReview)  // a team named "me" is not the user
    #expect(InboxSection.classify(pr(author: "alice", users: ["bob"]), viewer: "me") == nil)  // not about me at all
    #expect(InboxSection.classify(pr(author: "alice", draft: true, users: ["me"]), viewer: "me") == nil)  // others' drafts are not asks yet
}

@Test func theViewerIsMatchedCaseInsensitively() {
    #expect(InboxSection.classify(pr(author: "Me", draft: true), viewer: "me") == .yourDrafts)
    #expect(InboxSection.classify(pr(author: "alice", users: ["Me"]), viewer: "ME") == .needsYourReview)
}

@Test func countsGroupBySection() {
    let prs = [
        pr(1, draft: true), pr(2, draft: true), pr(3, review: .changesRequested), pr(4, author: "a", users: ["me"]),
        pr(5, author: "a", users: ["z"]),
    ]
    let counts = InboxSection.counts(of: prs, viewer: "me")
    #expect(counts == [.yourDrafts: 2, .needsAction: 1, .needsYourReview: 1])
    #expect(InboxSection.searchScopes == ["author:@me", "review-requested:@me"])
}

@Test func quickSearchesUseGitHubsQualifiers() {
    #expect(QuickSearch.allCases.map(\.scope) == ["author:@me", "assignee:@me", "involves:@me", "review-requested:@me"])
    #expect(QuickSearch.allCases.map(\.title) == ["Authored by me", "Assigned to me", "Involves me", "Review requests"])
    #expect(
        InboxSection.allCases.map(\.title) == [
            "Needs your review", "Needs your teams' review", "Your drafts",
            "Waiting for review or checks", "Needs action", "Ready to merge",
        ])
}

@Test func destinationsRoundTripThroughTheirSidebarTags() {
    let id = UUID()
    let all: [SidebarDestination] = [
        .inbox(.needsAction), .search(.involves), .savedView(id), .sources(["acme"]),
        .sources(["acme", "me"]), .repo(RepoId(owner: "acme", name: "api")),
    ]
    for d in all { #expect(SidebarDestination.from(tag: d.tag) == d) }
    #expect(SidebarDestination.from(tag: "inbox:nope") == nil && SidebarDestination.from(tag: "") == nil)
    #expect(SidebarDestination.from(tag: "repo:noslash") == nil)
    #expect(SidebarDestination.inbox(.waiting).isInbox && !SidebarDestination.search(.authored).isInbox)
}

@Test func hidingBlocksAndEntries() {
    var layout = SidebarLayout()
    #expect(layout.visibleSections.count == 6 && layout.visibleSearches.count == 4 && layout.needsInboxData)

    layout.hiddenEntries = ["inbox:needsAction", "search:involves"]
    #expect(!layout.visibleSections.contains(.needsAction) && layout.visibleSections.count == 5)
    #expect(!layout.visibleSearches.contains(.involves))
    #expect(!layout.shows(.inbox(.needsAction)) && layout.shows(.inbox(.waiting)))

    layout.inboxHidden = true
    #expect(layout.visibleSections.isEmpty && !layout.needsInboxData)  // hiding the Inbox also stops its queries
    #expect(layout.visibleSearches.count == 3)  // quick searches are their own block
    #expect(!layout.shows(.inbox(.waiting)))

    let view = SavedView(name: "Bugs", query: "label:bug")
    layout.savedViews = [view]
    #expect(layout.shows(.savedView(view.id)) && layout.visibleViews == [view])
    layout.hiddenEntries.insert("view:\(view.id.uuidString)")
    #expect(!layout.shows(.savedView(view.id)) && layout.visibleViews.isEmpty)
    #expect(!layout.shows(.savedView(UUID())))  // unknown view
    #expect(layout.shows(.sources(["x"])) && layout.shows(.repo(RepoId(owner: "o", name: "r"))))
}

@Test func layoutAndSavedViewsAreStoredPerAccount() throws {
    let defaults = UserDefaults(suiteName: "layout-\(UUID().uuidString)")!
    let alice = AccountScope(login: "alice"), bob = AccountScope(login: "bob")
    var layout = SidebarLayout()
    layout.inboxHidden = true
    layout.expandedSources = ["acme"]
    layout.savedViews = [SavedView(name: "Stale", query: "updated:<2025-01-01 org:acme")]
    layout.save(to: defaults, scope: alice)

    #expect(SidebarLayout.load(from: defaults, scope: alice) == layout)
    #expect(SidebarLayout.load(from: defaults, scope: bob) == SidebarLayout())  // bob never sees alice's views
    #expect(SidebarLayout.load(from: UserDefaults(suiteName: "empty-\(UUID().uuidString)")!, scope: alice) == SidebarLayout())
    #expect(SidebarLayout.defaultsKey(for: alice) != SidebarLayout.defaultsKey(for: bob))
}

@Test func searchCountsAskOneQueryWithVariablesAndReportBadQueries() async throws {
    let seen = LockedBox<[String]>([])
    let gh = MockGh { args in
        seen.update { $0 += args }
        return Data(
            #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":{"issueCount":7},"o1":null,"o2":{"issueCount":0}},"errors":[{"message":"Validation Failed","path":["o1"]}]}"#
                .utf8)
    }
    let (result, limits) = try await SearchCounts.fetch(
        ["author:@me", #"label:"has space" bad("#, "assignee:@me"], client: GraphQLClient(gh: gh))
    #expect(result.counts == ["author:@me": 7, "assignee:@me": 0])
    #expect(result.errors == [#"label:"has space" bad("#: "Validation Failed"])
    #expect(limits.count == 1)
    let args = seen.get()
    #expect(args.filter { $0 == "-f" }.count == 4)  // query plus three variables
    #expect(args.contains(#"q1=is:pr is:open label:"has space" bad("#))  // quotes travel as a variable, not in the query text
    #expect(SearchCounts.build(count: 2).contains("$q0: String!, $q1: String!"))
    let empty = try await SearchCounts.fetch([], client: GraphQLClient(gh: gh))
    #expect(empty.result.counts.isEmpty && empty.rateLimits.isEmpty)
}

@Test func savedViewNamesAndQueriesAreValidated() throws {
    let existing = [SavedView(name: "Bugs", query: "label:bug")]
    let ok = try SavedView.validate(name: "  Stale  ", query: "  updated:<2025-01-01 org:acme ", among: existing)
    #expect(ok.name == "Stale" && ok.query == "updated:<2025-01-01 org:acme")
    #expect(throws: SavedViewError.emptyName) { try SavedView.validate(name: "  ", query: "x", among: existing) }
    #expect(throws: SavedViewError.emptyQuery) { try SavedView.validate(name: "n", query: " \n", among: existing) }
    #expect(throws: SavedViewError.duplicateName("bugs")) { try SavedView.validate(name: "bugs", query: "x", among: existing) }
    // editing a view may keep its own name
    #expect(throws: Never.self) {
        try SavedView.validate(name: "BUGS", query: "label:bug is:draft", among: existing, editing: existing[0].id)
    }
    #expect(SavedViewError.emptyQuery.localizedDescription.contains("label:bug"))
}

@Test func theBuiltInSearchesLiveInsideTheViewsGroup() {
    var layout = SidebarLayout()
    #expect(layout.visibleSearches.count == 4)
    layout.savedViewsHidden = true  // the Views group is hidden, shortcuts and all
    #expect(layout.visibleSearches.isEmpty && layout.visibleViews.isEmpty)
    #expect(!layout.shows(.search(.authored)))
    layout.savedViewsHidden = false
    layout.quickSearchesHidden = true  // just the built-in searches
    #expect(layout.visibleSearches.isEmpty)
    #expect(layout.shows(.inbox(.waiting)))
}

@Test func everyInboxSectionHasAnApproximateGitHubQuery() {
    for s in InboxSection.allCases {
        #expect(!s.queryText.isEmpty && !s.queryText.contains("is:pr"))  // the app adds is:pr is:open itself
        #expect(s.queryText.contains("@me"))
    }
    #expect(InboxSection.yourDrafts.queryText == "author:@me draft:true")
    #expect(InboxSection.needsYourReview.queryText.contains("user-review-requested:@me"))  // direct requests only
    #expect(InboxSection.needsTeamsReview.queryText.contains("-user-review-requested:@me"))
    // sections GitHub cannot express exactly say so; the exact ones do not
    #expect(
        InboxSection.needsAction.queryNote != nil && InboxSection.readyToMerge.queryNote != nil && InboxSection.waiting.queryNote != nil)
    #expect(InboxSection.yourDrafts.queryNote == nil && InboxSection.needsYourReview.queryNote == nil)
}
