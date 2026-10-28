import Foundation

public extension SourcesQuery {
    /// Looks the login up on GitHub to learn whether it is a user or an org (one REST call).
    static func resolve(name: String, gh: any GhRunner) async throws -> Source {
        if name.contains("/") { return .repo(try await repository(name, gh: gh).fullName) }
        let data: Data
        do {
            data = try await gh.run(["api", "users/\(name)", "--jq", "{login: .login, type: .type}"])
        } catch let err as GhError where err.stderr.contains("404") || err.stderr.localizedCaseInsensitiveContains("not found") {
            throw SourceCatalog.EditError.notFound(name)
        }
        struct Info: Decodable { var login: String; var type: String }
        let info = try JSONDecoder().decode(Info.self, from: data)
        return info.type == "Organization" ? .org(info.login) : .user(info.login)
    }
}


/// Everything the add-source dialog can show about a name before it is added.
public struct SourceProfile: Sendable, Equatable {
    public enum Membership: Sendable, Equatable { case notApplicable, member, pending, notMember, unknown }

    public var source: Source
    public var displayName: String?
    /// A user's bio, or an organization's description.
    public var bio: String?
    public var company: String?
    public var location: String?
    public var website: String?
    public var publicRepos: Int?
    public var followers: Int?
    public var createdAt: Date?
    public var profileURL: URL?
    /// Open PRs in the source, and how many ask for the viewer's review. Nil if the count could not be read.
    public var openPRs: Int?
    public var reviewRequested: Int?
    /// For an organization: whether the viewer belongs to it.
    public var membership: Membership = .notApplicable
    /// Why PRs in this source cannot be read with the current login, e.g. an org that needs SAML SSO.
    public var accessProblem: String?
    public var needsSSO = false
    /// For a repository source.
    public var isPrivate: Bool?
    public var isArchived: Bool?
    public var isFork: Bool?
    public var language: String?
    public var stars: Int?

    public init(source: Source) { self.source = source }
}

public extension SourcesQuery {
    private struct UserInfo: Decodable {
        var login: String
        var type: String
        var name: String?
        var bio: String?
        var description: String?
        var company: String?
        var location: String?
        var blog: String?
        var publicRepos: Int?
        var followers: Int?
        var createdAt: Date?
        var htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case login, type, name, bio, description, company, location, blog, followers
            case publicRepos = "public_repos", createdAt = "created_at", htmlURL = "html_url"
        }
    }

    private static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    struct RepoInfoResponse: Decodable {
        var fullName: String
        var description: String?
        var homepage: String?
        var isPrivate: Bool
        var archived: Bool
        var fork: Bool?
        var stars: Int
        var language: String?
        var createdAt: Date?
        var htmlURL: String?

        enum CodingKeys: String, CodingKey {
            case description, homepage, archived, fork, language
            case fullName = "full_name", isPrivate = "private", stars = "stargazers_count"
            case createdAt = "created_at", htmlURL = "html_url"
        }
    }

    /// The repository `owner/name` as GitHub spells it (one REST call), or `notFound`.
    private static func repository(_ name: String, gh: any GhRunner) async throws -> RepoInfoResponse {
        let data: Data
        do { data = try await gh.run(["api", "repos/\(name)"]) }
        catch let err as GhError where err.stderr.contains("404") || err.stderr.localizedCaseInsensitiveContains("not found") {
            throw SourceCatalog.EditError.notFound(name)
        }
        return try GraphQLClient.decoder.decode(RepoInfoResponse.self, from: data)
    }

    private static func repositoryProfile(_ name: String, gh: any GhRunner) async throws -> SourceProfile {
        let info = try await repository(name, gh: gh)
        let source = Source.repo(info.fullName)
        async let counts = SourceCountsQuery.fetch([source], client: GraphQLClient(gh: gh)).counts[source.id]
        var p = SourceProfile(source: source)
        p.bio = clean(info.description)
        p.website = clean(info.homepage)
        p.isPrivate = info.isPrivate
        p.isArchived = info.archived
        p.isFork = info.fork
        p.language = clean(info.language)
        p.stars = info.stars
        p.createdAt = info.createdAt
        p.profileURL = info.htmlURL.flatMap(URL.init(string:))
        if let c = await counts {
            if let problem = c.error { p.accessProblem = problem; p.needsSSO = c.needsSSO }
            else { p.openPRs = c.open; p.reviewRequested = c.reviewRequested }
        }
        return p
    }

    /// Looks a name up and gathers what the dialog shows. The profile call decides the result; the PR counts and
    /// organization membership are extras fetched alongside it, and failing to get them never fails the lookup.
    /// Costs one REST call, one GraphQL point, and for an organization one more REST call.
    static func profile(name: String, gh: any GhRunner) async throws -> SourceProfile {
        if name.contains("/") { return try await repositoryProfile(name, gh: gh) }
        let data: Data
        do { data = try await gh.run(["api", "users/\(name)"]) }
        catch let err as GhError where err.stderr.contains("404") || err.stderr.localizedCaseInsensitiveContains("not found") {
            throw SourceCatalog.EditError.notFound(name)
        }
        let decoder = GraphQLClient.decoder
        let info = try decoder.decode(UserInfo.self, from: data)
        let isOrg = info.type == "Organization"
        let source: Source = isOrg ? .org(info.login) : .user(info.login)

        async let counts = SourceCountsQuery.fetch([source], client: GraphQLClient(gh: gh)).counts[source.id]
        async let membership = isOrg ? organizationMembership(info.login, gh: gh) : .notApplicable

        var p = SourceProfile(source: source)
        p.displayName = clean(info.name).flatMap { $0.caseInsensitiveCompare(info.login) == .orderedSame ? nil : $0 }
        p.bio = clean(isOrg ? info.description : info.bio)
        p.company = clean(info.company)
        p.location = clean(info.location)
        p.website = clean(info.blog)
        p.publicRepos = info.publicRepos
        p.followers = isOrg ? nil : info.followers
        p.createdAt = info.createdAt
        p.profileURL = info.htmlURL.flatMap(URL.init(string:))
        if let c = await counts {
            if let problem = c.error { p.accessProblem = problem; p.needsSSO = c.needsSSO }
            else { p.openPRs = c.open; p.reviewRequested = c.reviewRequested }
        }
        p.membership = await membership
        return p
    }

    private static func organizationMembership(_ org: String, gh: any GhRunner) async -> SourceProfile.Membership {
        do {
            let state = try await gh.run(["api", "user/memberships/orgs/\(org)", "--jq", ".state"])
            return String(decoding: state, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "pending" ? .pending : .member
        } catch let err as GhError where err.stderr.contains("404") || err.stderr.localizedCaseInsensitiveContains("not found")
            || err.stderr.contains("403") {
            return .notMember
        } catch { return .unknown }
    }
}
