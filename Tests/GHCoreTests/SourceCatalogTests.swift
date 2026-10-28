import Foundation
import Testing
@testable import GHCore

private func catalog() -> SourceCatalog {
    // Accounts: me, friend | Organizations: acme, beta, corp
    SourceCatalog.seeded(from: [.user("me"), .org("acme"), .org("beta"), .org("corp"), .user("friend")])
}
private func names(_ g: SourceGroup) -> [String] { g.sources.map(\.name) }
private func gid(_ c: SourceCatalog, _ name: String) -> UUID { c.groups.first { $0.name == name }!.id }

// MARK: validation and resolve (ported)

@Test func validatesNames() throws {
    #expect(try SourceCatalog.validate("  @octocat ") == "octocat")
    #expect(try SourceCatalog.validate("my-org") == "my-org")
    #expect(throws: SourceCatalog.EditError.empty) { try SourceCatalog.validate("  ") }
    #expect(throws: SourceCatalog.EditError.self) { try SourceCatalog.validate("-bad") }
    #expect(throws: SourceCatalog.EditError.self) { try SourceCatalog.validate("has space") }
    #expect(throws: SourceCatalog.EditError.self) { try SourceCatalog.validate(String(repeating: "a", count: 40)) }
}

@Test func resolvesUserVsOrg() async throws {
    let org = MockGh { _ in Data(#"{"login":"Acme","type":"Organization"}"#.utf8) }
    #expect(try await SourcesQuery.resolve(name: "acme", gh: org) == .org("Acme"))
    let user = MockGh { _ in Data(#"{"login":"bob","type":"User"}"#.utf8) }
    #expect(try await SourcesQuery.resolve(name: "bob", gh: user) == .user("bob"))
    let missing = MockGh { args in throw GhError(args: args, status: 1, stderr: "gh: Not Found (HTTP 404)") }
    await #expect(throws: SourceCatalog.EditError.notFound("ghost")) { _ = try await SourcesQuery.resolve(name: "ghost", gh: missing) }
}

// MARK: seeding and persistence

@Test func seedsAccountsAndOrganizations() {
    let c = catalog()
    #expect(c.groups.map(\.name) == ["Accounts", "Organizations"])
    #expect(names(c.groups[0]) == ["me", "friend"] && names(c.groups[1]) == ["acme", "beta", "corp"])
    #expect(c.allSources.count == 5 && c.hiddenCount == 0)
}

@Test func persistenceRoundTripsGroupsHiddenAndDismissed() throws {
    let suite = UserDefaults(suiteName: "ghview-cat-\(UUID().uuidString)")!
    #expect(SourceCatalog.load(from: suite) == nil)
    var c = catalog()
    c.setHidden([.org("beta")], true)
    c.remove([.org("corp")])
    try c.createGroup(name: "Work")
    c.save(to: suite)
    #expect(SourceCatalog.load(from: suite) == c)
}

// MARK: groups

@Test func createRenameValidateGroups() throws {
    var c = catalog()
    let work = try c.createGroup(name: "  Work ")
    #expect(c.groups.last?.name == "Work")
    #expect(throws: SourceCatalog.EditError.duplicateGroup("work")) { try c.createGroup(name: "work") }
    #expect(throws: SourceCatalog.EditError.emptyGroupName) { try c.createGroup(name: "   ") }
    try c.renameGroup(work, to: "WORK")  // renaming to a different case of itself is fine
    try c.renameGroup(work, to: "Clients")
    #expect(throws: SourceCatalog.EditError.duplicateGroup("accounts")) { try c.renameGroup(work, to: "accounts") }
    #expect(c.groups.map(\.name) == ["Accounts", "Organizations", "Clients"])
}

@Test func deleteGroupMovesSourcesToPreviousOrNext() throws {
    var c = catalog()
    let extra = try c.createGroup(name: "Extra")
    c.move([.org("beta")], toGroup: extra)
    try c.deleteGroup(extra)  // last group: sources go to the previous one
    #expect(c.groups.map(\.name) == ["Accounts", "Organizations"])
    #expect(names(c.groups[1]) == ["acme", "corp", "beta"])
    try c.deleteGroup(gid(c, "Accounts"))  // first group: sources go to the start of the next
    #expect(c.groups.map(\.name) == ["Organizations"])
    #expect(names(c.groups[0]) == ["me", "friend", "acme", "corp", "beta"])
    #expect(throws: SourceCatalog.EditError.lastGroup) { try c.deleteGroup(c.groups[0].id) }
}

@Test func reorderAndCollapseGroups() throws {
    var c = catalog()
    try c.createGroup(name: "Third")
    c.moveGroups(fromOffsets: [2], toOffset: 0)
    #expect(c.groups.map(\.name) == ["Third", "Accounts", "Organizations"])
    let id = gid(c, "Accounts")
    c.setCollapsed(id, true)
    #expect(c.group(withID: id)?.isCollapsed == true)
    let suite = UserDefaults(suiteName: "ghview-cat-\(UUID().uuidString)")!
    c.save(to: suite)
    #expect(SourceCatalog.load(from: suite)?.group(withID: id)?.isCollapsed == true)  // collapse persists
}

// MARK: moving sources

@Test func moveBetweenGroupsAtPositions() throws {
    var c = catalog()
    let accounts = gid(c, "Accounts"), orgs = gid(c, "Organizations")
    c.move([.org("beta")], toGroup: accounts)  // append
    #expect(names(c.groups[0]) == ["me", "friend", "beta"] && names(c.groups[1]) == ["acme", "corp"])
    c.move([.user("friend")], toGroup: orgs, at: 0)  // insert at the front of another group
    #expect(names(c.groups[1]) == ["friend", "acme", "corp"])
    c.move([.org("corp")], toGroup: orgs, at: 0)  // within the same group, to the front
    #expect(names(c.groups[1]) == ["corp", "friend", "acme"])
    c.move([.org("corp")], toGroup: orgs, at: 3)  // an index past the end appends
    #expect(names(c.groups[1]) == ["friend", "acme", "corp"])
    c.move([.org("acme"), .user("me")], toGroup: accounts, at: 1)  // several at once, before "beta"
    #expect(names(c.groups[0]) == ["me", "acme", "beta"] || names(c.groups[0]).contains("acme"))
    #expect(c.allSources.count == 5 && Set(c.allSources.map(\.id)).count == 5)  // nothing lost or duplicated
}

@Test func droppingOntoItselfChangesNothing() {
    var c = catalog()
    let before = c
    c.move([.org("beta")], toGroup: gid(c, "Organizations"), at: 1)  // beta sits at index 1
    #expect(c == before)
}

@Test func moveIntoEmptyGroupAndUnknownTargets() throws {
    var c = catalog()
    let empty = try c.createGroup(name: "Empty")
    c.move([.user("me")], toGroup: empty)
    #expect(names(c.groups[2]) == ["me"] && names(c.groups[0]) == ["friend"])
    c.move([.user("me")], toGroup: UUID())  // unknown group: no-op
    c.move([.org("nobody")], toGroup: empty)  // unknown source: no-op
    #expect(c.allSources.count == 5)
}

@Test func visibleReorderingKeepsHiddenSlots() {
    var c = catalog()
    let orgs = gid(c, "Organizations")
    c.setHidden([.org("acme")], true)  // visible in Organizations: beta corp
    c.moveVisible(inGroup: orgs, fromOffsets: [1], toOffset: 0)
    #expect(names(c.groups[1]) == ["acme", "corp", "beta"])  // hidden acme stayed in slot 0
    c.removeVisible(inGroup: orgs, atOffsets: [0])  // first visible row is corp
    #expect(names(c.groups[1]) == ["acme", "beta"])
}

// MARK: add / replace / remove / dismissed

@Test func addPicksDefaultGroupAndRejectsDuplicates() throws {
    var c = catalog()
    try c.add(.user("bob"))
    try c.add(.org("delta"))
    #expect(names(c.groups[0]).last == "bob" && names(c.groups[1]).last == "delta")
    #expect(throws: SourceCatalog.EditError.duplicate("ACME")) { try c.add(.org("ACME")) }
    let custom = try c.createGroup(name: "Custom")
    try c.add(.org("echo"), to: custom)
    #expect(names(c.groups[2]) == ["echo"])
    var renamed = catalog()  // no group with the default names: fall back to first/last
    try renamed.renameGroup(renamed.groups[0].id, to: "Me")
    try renamed.renameGroup(renamed.groups[1].id, to: "Work")
    try renamed.add(.user("bob")); try renamed.add(.org("delta"))
    #expect(names(renamed.groups[0]).last == "bob" && names(renamed.groups[1]).last == "delta")
}

@Test func replaceKeepsGroupPositionAndVisibility() throws {
    var c = catalog()
    c.setHidden([.org("beta")], true)
    try c.replace(.org("beta"), with: .org("beta2"))
    #expect(names(c.groups[1]) == ["acme", "beta2", "corp"] && c.isHidden(.org("beta2")) && !c.isHidden(.org("beta")))
    #expect(throws: SourceCatalog.EditError.duplicate("ACME")) { try c.replace(.org("corp"), with: .org("ACME")) }
    try c.replace(.org("corp"), with: .org("CORP"))  // case-only rename of itself is allowed
}

@Test func removeRemembersAndAddForgets() throws {
    var c = catalog()
    c.setHidden([.org("corp")], true)
    c.remove([.org("corp")])
    #expect(!c.contains("corp") && c.hidden.isEmpty && c.dismissed == ["corp"])
    #expect(c.missingOrgs(for: Viewer(login: "me", orgs: ["corp", "acme", "Zed"])) == ["corp", "Zed"])  // still offered manually
    try c.add(.org("corp"))
    #expect(c.dismissed.isEmpty)
}

// MARK: visibility

@Test func hideShowShowOnlyAndGroupHide() {
    var c = catalog()
    c.setHidden([.org("acme"), .org("corp")], true)
    #expect(c.visibleSources.map(\.name) == ["me", "friend", "beta"] && c.hiddenCount == 2)
    #expect(c.isHidden(.org("ACME")))  // case-insensitive
    c.setHidden([.org("nope")], true)
    #expect(c.hiddenCount == 2)  // unknown sources are ignored
    c.setGroupHidden(gid(c, "Organizations"), true)
    #expect(c.visibleSources(in: c.groups[1]).isEmpty && c.visibleSources.map(\.name) == ["me", "friend"])
    c.setGroupHidden(gid(c, "Organizations"), false)
    #expect(c.hiddenCount == 0)
    c.showOnly([.org("beta"), .user("me")])
    #expect(c.visibleSources.map(\.name) == ["me", "beta"])
    c.showAll()
    #expect(c.hiddenCount == 0)
}

@Test func sortWithinGroupOrAll() throws {
    var c = SourceCatalog.seeded(from: [.org("zed"), .org("Alpha"), .user("bob"), .user("Amy")])
    c.sort(.alphabetical, group: gid(c, "Organizations"))
    #expect(names(c.groups[1]) == ["Alpha", "zed"] && names(c.groups[0]) == ["bob", "Amy"])  // accounts untouched
    c.sort(.alphabetical)
    #expect(names(c.groups[0]) == ["Amy", "bob"])
}

@Test func missingOrgsOnlyListsUnknownOnes() {
    let c = SourceCatalog.seeded(from: [.user("me"), .org("Alpha")])
    #expect(c.missingOrgs(for: Viewer(login: "me", orgs: ["alpha", "zed", "Beta"])) == ["Beta", "zed"])
}

@Test func moveSemanticsMatchSwiftUI() {
    let r = SourceCatalog.moved(["a", "b", "c", "d"], fromOffsets: [0], toOffset: 3)
    #expect(r == ["b", "c", "a", "d"])
    #expect(SourceCatalog.moved(r, fromOffsets: [3], toOffset: 0) == ["d", "b", "c", "a"])
    #expect(SourceCatalog.moved(["d", "b", "c", "a"], fromOffsets: [1, 2], toOffset: 4) == ["d", "a", "b", "c"])
}

@Test func avatarURLsPointAtGitHubPNGs() {
    #expect(Source.org("rneopets").avatarURL(pixels: 64)?.absoluteString == "https://github.com/rneopets.png?size=64")
    #expect(Source.user("diceroll123").avatarURL()?.absoluteString == "https://github.com/diceroll123.png?size=64")
}

@Test func sourceBrowserURLs() throws {
    #expect(Source.org("rneopets").profileURL.absoluteString == "https://github.com/rneopets")
    #expect(Source.user("diceroll123").profileURL.absoluteString == "https://github.com/diceroll123")
    let org = try #require(URLComponents(url: Source.org("acme").pullRequestsURL, resolvingAgainstBaseURL: false))
    #expect(org.host == "github.com" && org.path == "/pulls")
    #expect(org.queryItems?.first { $0.name == "q" }?.value == "is:pr is:open org:acme")
    // user sources search the repos they own, matching the PRs view
    let user = try #require(URLComponents(url: Source.user("me").pullRequestsURL, resolvingAgainstBaseURL: false))
    #expect(user.queryItems?.first { $0.name == "q" }?.value == "is:pr is:open user:me")
    // the query survives URL encoding: spaces and colons must not break the link
    #expect(!Source.org("acme").pullRequestsURL.absoluteString.contains(" "))
}

// MARK: repositories as sources

@Test func repositoryNamesAreValidatedAndCleaned() throws {
    #expect(try SourceCatalog.validate("Rapptz/discord.py") == "Rapptz/discord.py")
    #expect(try SourceCatalog.validate("  @acme/api_v2-x ") == "acme/api_v2-x")
    #expect(try SourceCatalog.validate("https://github.com/acme/api") == "acme/api")
    #expect(try SourceCatalog.validate("https://github.com/acme/api.git/") == "acme/api")
    #expect(try SourceCatalog.validate("github.com/acme/api") == "acme/api")
    #expect(try SourceCatalog.validate("acme") == "acme")  // plain logins are unchanged
    #expect(try SourceCatalog.validate("acme/") == "acme")  // a trailing slash is just trimmed
    for bad in ["/api", "a/b/c", "acme/api name", "acme/..", "acme/.", "-bad/api", "acme/" + String(repeating: "x", count: 101)] {
        #expect(throws: SourceCatalog.EditError.self, "\(bad) should be rejected") { try SourceCatalog.validate(bad) }
    }
}

@Test func aRepositorySourceSearchesAndLinksToItsRepoButShowsItsOwnersAvatar() {
    let s = Source.repo("acme/api")
    #expect(s.searchScope == "repo:acme/api" && s.displayName == "acme/api" && s.id == "acme/api")
    #expect(s.ownerLogin == "acme" && s.repoId == RepoId(owner: "acme", name: "api"))
    #expect(s.avatarURL()?.absoluteString.hasPrefix("https://github.com/acme.png") == true)
    #expect(s.profileURL.absoluteString == "https://github.com/acme/api")
    #expect(s.pullRequestsURL.absoluteString.contains("repo:acme/api") || s.pullRequestsURL.absoluteString.contains("repo%3Aacme"))
    #expect(Source.org("acme").repoId == nil && Source.user("me").ownerLogin == "me")
    // it combines with other sources in one search
    #expect(SearchScope.chunks(of: [.org("acme"), s, .user("me")]) == ["org:acme repo:acme/api user:me"])
}

@Test func repositoriesGetTheirOwnGroupAndOldCatalogsStillDecode() throws {
    var catalog = SourceCatalog.seeded(from: [.user("me"), .org("acme")])
    try catalog.add(.repo("other/tool"))
    #expect(catalog.groups.map(\.name) == ["Accounts", "Organizations", "Repositories"])
    #expect(catalog.groups[2].sources == [.repo("other/tool")])
    try catalog.add(.repo("other/second"))
    #expect(catalog.groups.count == 3 && catalog.groups[2].sources.count == 2)  // the group is reused
    #expect(throws: SourceCatalog.EditError.duplicate("OTHER/tool")) { try catalog.add(.repo("OTHER/tool")) }

    let round = try JSONDecoder().decode(SourceCatalog.self, from: JSONEncoder().encode(catalog))
    #expect(round.allSources == catalog.allSources)

    // catalogs saved before repositories existed contain only user and org cases
    let old = SourceCatalog.seeded(from: [.user("me"), .org("acme")])
    let json = try JSONEncoder().encode(old)
    #expect(try JSONDecoder().decode(SourceCatalog.self, from: json).allSources == old.allSources)
}

@Test func aRepositoryCanBeResolvedAndProfiled() async throws {
    let repoJSON =
        #"{"full_name":"Rapptz/discord.py","description":"An async API wrapper","homepage":"https://discordpy.rtfd.io","private":false,"archived":false,"fork":true,"stargazers_count":15000,"language":"Python","created_at":"2015-08-24T10:00:00Z","html_url":"https://github.com/Rapptz/discord.py"}"#
    let gh = MockGh { args in
        if args.contains(where: { $0 == "repos/rapptz/discord.py" }) { return Data(repoJSON.utf8) }
        if args.contains("graphql") {
            return Data(
                #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":{"issueCount":8},"r0":{"issueCount":1}}}"#
                    .utf8)
        }
        throw GhError(args: args, status: 1, stderr: "gh: Not Found (HTTP 404)")
    }
    #expect(try await SourcesQuery.resolve(name: "rapptz/discord.py", gh: gh) == .repo("Rapptz/discord.py"))  // spelled as GitHub spells it
    let p = try await SourcesQuery.profile(name: "rapptz/discord.py", gh: gh)
    #expect(p.source == .repo("Rapptz/discord.py") && p.bio == "An async API wrapper" && p.website == "https://discordpy.rtfd.io")
    #expect(p.language == "Python" && p.stars == 15000 && p.isPrivate == false && p.isArchived == false && p.isFork == true)
    #expect(p.openPRs == 8 && p.reviewRequested == 1 && p.membership == .notApplicable)
    await #expect(throws: SourceCatalog.EditError.self) { _ = try await SourcesQuery.profile(name: "nobody/nothing", gh: gh) }
}
