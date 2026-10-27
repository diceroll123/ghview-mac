import Foundation
import Testing
@testable import GHCore

@Test func fetchesViewerAndOrgs() async throws {
    let data = try fixture("viewer")
    let viewer = try await SourcesQuery.fetchViewer(client: GraphQLClient(gh: MockGh { _ in data }))
    #expect(viewer.login == "diceroll123")
    #expect(viewer.orgs == ["rneopets"])
}

@Test func decodesReposFixture() async throws {
    let data = try fixture("repos")
    let page = try await ReposQuery.fetch(owner: "diceroll123", client: GraphQLClient(gh: MockGh { _ in data }))
    #expect(!page.repos.isEmpty)
    let repo = try #require(page.repos.first)
    #expect(repo.id.owner == "diceroll123")
    #expect(repo.canPush)
}

@Test func assemblesSources() {
    let viewer = Viewer(login: "me", orgs: ["zeta", "Alpha", "ME"])
    var cfg = SourceConfig()
    cfg.orgs = ["alpha", "extra"]
    cfg.users = ["friend", "Zeta"]
    cfg.exclude = ["EXTRA"]
    let names = SourcesQuery.assemble(viewer: viewer, config: cfg).map(\.displayName)
    #expect(names == ["@me", "Alpha", "zeta", "@friend"])

    cfg.includeSelf = false
    cfg.autoFetchOrgs = false
    #expect(SourcesQuery.assemble(viewer: viewer, config: cfg).map(\.displayName) == ["alpha", "@friend", "@Zeta"])
}

@Test func sourceSearchScopeCoversAllReposPRs() {
    #expect(Source.user("me").searchScope == "user:me")
    #expect(Source.org("acme").searchScope == "org:acme")
}

// MARK: profile for the add-source dialog

private func profileGh(user: String, membership: String? = nil, counts: String? = nil, membershipError: String? = nil) -> MockGh {
    MockGh { args in
        if args.starts(with: ["api", "users/octo"]) { return Data(user.utf8) }
        if args.starts(with: ["api", "user/memberships/orgs/octo"]) {
            if let membershipError { throw GhError(args: args, status: 1, stderr: membershipError) }
            return Data((membership ?? "active").utf8)
        }
        if args.contains("graphql") {
            return Data((counts ?? #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":{"issueCount":12},"r0":{"issueCount":3}}}"#).utf8)
        }
        throw GhError(args: args, status: 1, stderr: "unexpected \(args)")
    }
}

private let orgJSON = #"{"login":"octo","type":"Organization","name":"Octo Inc","description":"We make tentacles","company":null,"location":"Reykjavik","blog":"https://octo.dev","public_repos":42,"followers":900,"created_at":"2014-03-02T10:00:00Z","html_url":"https://github.com/octo"}"#

@Test func anOrganizationProfileGathersEverythingTheDialogShows() async throws {
    let p = try await SourcesQuery.profile(name: "octo", gh: profileGh(user: orgJSON))
    #expect(p.source == .org("octo"))
    #expect(p.displayName == "Octo Inc" && p.bio == "We make tentacles")
    #expect(p.location == "Reykjavik" && p.company == nil && p.website == "https://octo.dev")
    #expect(p.publicRepos == 42)
    #expect(p.followers == nil)                       // followers are shown for people, not organizations
    #expect(p.createdAt != nil && p.profileURL?.absoluteString == "https://github.com/octo")
    #expect(p.openPRs == 12 && p.reviewRequested == 3)
    #expect(p.membership == .member)
    #expect(p.accessProblem == nil)
}

@Test func aUserProfileHasNoMembershipAndAnEmptyDisplayNameIsDropped() async throws {
    let user = #"{"login":"octo","type":"User","name":"octo","bio":" hi ","company":"","followers":5,"public_repos":1,"created_at":"2020-01-01T00:00:00Z"}"#
    let p = try await SourcesQuery.profile(name: "octo", gh: profileGh(user: user))
    #expect(p.source == .user("octo"))
    #expect(p.displayName == nil)                     // same as the login, so not repeated
    #expect(p.bio == "hi" && p.company == nil)
    #expect(p.followers == 5 && p.membership == .notApplicable)
}

@Test func extrasFailingNeverFailTheLookup() async throws {
    let gh = MockGh { args in
        if args.starts(with: ["api", "users/octo"]) { return Data(orgJSON.utf8) }
        throw GhError(args: args, status: 1, stderr: "network down")
    }
    let p = try await SourcesQuery.profile(name: "octo", gh: gh)
    #expect(p.source == .org("octo") && p.publicRepos == 42)
    #expect(p.openPRs == nil && p.membership == .unknown && p.accessProblem == nil)
}

@Test func notAMemberAndSAMLProblemsAreReported() async throws {
    let saml = #"{"data":{"rateLimit":{"remaining":1,"limit":2,"cost":1,"resetAt":null},"o0":null,"r0":null},"errors":[{"message":"Resource protected by organization SAML enforcement. You must grant your credentials SAML access.","path":["o0"]}]}"#
    let gh = MockGh { args in
        if args.starts(with: ["api", "users/octo"]) { return Data(orgJSON.utf8) }
        if args.contains(where: { $0.hasPrefix("user/memberships") }) { throw GhError(args: args, status: 1, stderr: "gh: Not Found (HTTP 404)") }
        throw GhError(args: args, status: 1, stderr: "", stdout: Data(saml.utf8))
    }
    let p = try await SourcesQuery.profile(name: "octo", gh: gh)
    #expect(p.membership == .notMember)
    #expect(p.needsSSO && p.accessProblem?.contains("SAML") == true)
    #expect(p.openPRs == nil)

    let pending = try await SourcesQuery.profile(name: "octo", gh: profileGh(user: orgJSON, membership: "pending"))
    #expect(pending.membership == .pending)
}

@Test func anUnknownNameIsNotFound() async {
    let gh = MockGh { args in throw GhError(args: args, status: 1, stderr: "gh: Not Found (HTTP 404)") }
    await #expect(throws: SourceCatalog.EditError.self) { _ = try await SourcesQuery.profile(name: "nobody", gh: gh) }
}
