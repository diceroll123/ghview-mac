import Foundation

public enum PrAction: String, Sendable, CaseIterable {
    case approve, merge, autoMerge, disableAutoMerge, close, reopen, markReady, rebase
}

public enum MergeMethod: String, Sendable, CaseIterable, Codable {
    case squash, merge, rebase

    public var title: String {
        switch self {
        case .squash: "Squash and merge"
        case .merge: "Create a merge commit"
        case .rebase: "Rebase and merge"
        }
    }
}

public struct ActionOptions: Sendable {
    public var mergeMethod: MergeMethod
    public init(mergeMethod: MergeMethod = .squash) {
        self.mergeMethod = mergeMethod
    }

    /// The method to use in `repo`: the preferred one if its settings allow it, otherwise the first allowed
    /// (squash, merge, rebase). Nil when the repository allows none. Unknown settings keep the preference.
    public func method(for repo: RepoInfo?) -> MergeMethod? {
        guard let allowed = repo?.allowedMergeMethods else { return mergeMethod }
        if allowed.contains(mergeMethod) { return mergeMethod }
        return [MergeMethod.squash, .merge, .rebase].first { allowed.contains($0) }
    }
}

public enum ActionOutcome: Sendable, Equatable {
    /// What was asked for has happened.
    case done(String)
    /// GitHub accepted the request but it has not completed: the PR is in a merge queue, or waiting on auto-merge.
    case queued(String)
    case skipped(String)
}

/// What GitHub says about a PR right after a merge command, read back instead of assumed.
struct MergeState: Decodable, Sendable {
    var state: String
    var isInMergeQueue: Bool?
    var autoMergeRequest: Present?
    struct Present: Decodable, Sendable {}
}

/// Context about the signed-in user and repo used for skip and permission decisions.
public struct ActionContext: Sendable {
    public var viewerLogin: String
    public var repo: RepoInfo?
    public init(viewerLogin: String, repo: RepoInfo?) { self.viewerLogin = viewerLogin; self.repo = repo }

    func canPush() -> Bool { repo?.canPush ?? false }
}

extension Permissions {
    /// Shown when the repository's permissions have not been loaded (yet, or at all). It is not a denial:
    /// the user may well have access.
    public static func unknownPermissions(_ pr: PR) -> String { "Permissions for \(pr.repo.fullName) are not loaded yet" }
}

public enum Permissions {
    /// Returns a reason the action is not allowed, or nil if it is. Ported from the Rust app.
    public static func denial(_ action: PrAction, pr: PR, ctx: ActionContext) -> String? {
        if ctx.repo == nil {
            // Without repo metadata we cannot tell "no access" from "not loaded". Own-PR close/reopen/ready and
            // approving someone else's PR do not need it; everything else waits for it.
            switch action {
            case .approve: return pr.author == ctx.viewerLogin ? "Cannot approve your own PR" : nil
            case .close, .reopen, .markReady: return pr.author == ctx.viewerLogin ? nil : unknownPermissions(pr)
            default: return unknownPermissions(pr)
            }
        }
        // An archived repository is read-only: nothing can be done to its PRs, whatever the permissions say.
        if ctx.repo?.isArchived == true { return "\(pr.repo.fullName) is archived and read-only" }
        switch action {
        case .approve:
            return pr.author == ctx.viewerLogin ? "Cannot approve your own PR" : nil
        case .merge:
            if !ctx.canPush() { return "No push access to \(pr.repo.fullName)" }
            return ctx.repo?.allowedMergeMethods.isEmpty == true ? "\(pr.repo.fullName) allows no merge method" : nil
        case .rebase, .disableAutoMerge:
            return ctx.canPush() ? nil : "No push access to \(pr.repo.fullName)"
        case .autoMerge:
            if !ctx.canPush() { return "No push access to \(pr.repo.fullName)" }
            if ctx.repo?.allowedMergeMethods.isEmpty == true { return "\(pr.repo.fullName) allows no merge method" }
            return (ctx.repo?.allowAutoMerge ?? false) ? nil : "Auto-merge is not enabled for \(pr.repo.fullName)"
        case .close, .reopen, .markReady:
            return (ctx.canPush() || pr.author == ctx.viewerLogin) ? nil : "No permission on \(pr.repo.fullName)"
        }
    }

    /// Returns a reason the action would be a no-op, or nil if it should run.
    public static func noOp(_ action: PrAction, pr: PR, options: ActionOptions, ctx: ActionContext) -> String? {
        switch action {
        case .approve: return pr.viewerApproved ? "Already approved" : nil
        case .close: return pr.isOpen ? nil : "Already closed"
        case .reopen: return pr.isOpen ? "Already open" : nil
        case .markReady: return pr.isDraft ? nil : "Not a draft"
        case .merge:
            if !pr.isOpen { return "Not open" }
            return pr.isDraft ? "Draft PRs cannot be merged" : nil
        case .autoMerge:
            if !pr.isOpen { return "Not open" }
            if pr.isDraft { return "Draft PRs cannot be merged" }
            return pr.autoMerge ? "Auto-merge already enabled" : nil
        case .disableAutoMerge:
            return pr.autoMerge ? nil : "Auto-merge is not enabled"
        case .rebase:
            if !pr.isOpen { return "Not open" }
            switch pr.mergeable {
            case .clean: return "Already up to date"
            case .dirty: return "Has conflicts, cannot rebase"
            default: return nil  // GitHub rejects a conflicting rebase atomically
            }
        }
    }
}

/// Serializes work per key (e.g. `owner/repo/base`) so concurrent merges into one branch do not race.
public actor KeyedSerializer {
    private var tails: [String: Task<Void, Never>] = [:]
    public init() {}

    public func run<T: Sendable>(key: String, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tails[key]
        let task = Task<Result<T, Error>, Never> {
            await previous?.value
            do { return .success(try await op()) } catch { return .failure(error) }
        }
        tails[key] = Task { _ = await task.value }
        return try await task.value.get()
    }
}

public struct PrActions: Sendable {
    public let gh: any GhRunner
    public let serializer: KeyedSerializer
    public var sleep: @Sendable (Duration) async -> Void

    public init(
        gh: any GhRunner, serializer: KeyedSerializer = KeyedSerializer(),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.gh = gh
        self.serializer = serializer
        self.sleep = sleep
    }

    static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1)]

    public func perform(_ action: PrAction, pr: PR, options: ActionOptions, ctx: ActionContext) async throws -> ActionOutcome {
        if let reason = Permissions.denial(action, pr: pr, ctx: ctx) { return .skipped(reason) }
        if let reason = Permissions.noOp(action, pr: pr, options: options, ctx: ctx) { return .skipped(reason) }
        let n = String(pr.number), repo = pr.repo.fullName
        switch action {
        case .approve:
            // Approve exactly the revision the user inspected: bail if the head moved, and bind the review to it.
            let current = String(decoding: try await gh.run(["api", "repos/\(repo)/pulls/\(n)", "--jq", ".head.sha"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if current != pr.headSha { return .skipped(Self.headMoved(n)) }
            _ = try await gh.run([
                "api", "-X", "POST", "repos/\(repo)/pulls/\(n)/reviews",
                "-f", "event=APPROVE", "-f", "commit_id=\(pr.headSha)",
            ])
            return .done("Approved #\(n)")
        case .close:
            _ = try await gh.run(["pr", "close", n, "-R", repo])
            return .done("Closed #\(n)")
        case .reopen:
            _ = try await gh.run(["pr", "reopen", n, "-R", repo])
            return .done("Reopened #\(n)")
        case .markReady:
            _ = try await gh.run(["pr", "ready", n, "-R", repo])
            return .done("Marked #\(n) ready")
        case .rebase:
            _ = try await gh.run(["pr", "update-branch", n, "-R", repo, "--rebase"])
            return .done("Rebased #\(n)")
        case .merge, .autoMerge:
            let auto = action == .autoMerge
            guard let method = options.method(for: ctx.repo) else { return .skipped("\(repo) allows no merge method") }
            var args = ["pr", "merge", n, "-R", repo]
            if auto { args.append("--auto") }
            args.append("--\(method.rawValue)")
            // GitHub rejects the merge if the head moved since the user inspected it. The same SHA is used on every retry.
            args += ["--match-head-commit", pr.headSha]
            let key = "\(repo)/\(pr.baseRef)"
            let gh = self.gh, sleep = self.sleep
            let finalArgs = args
            do {
                try await serializer.run(key: key) {
                    try await Self.withRetry(sleep: sleep) { _ = try await gh.run(finalArgs) }
                }
            } catch let err as GhError where err.stderr.lowercased().contains("head branch was modified") {
                return .skipped(Self.headMoved(n))
            }
            let note = method == options.mergeMethod ? "" : " (\(method.rawValue); \(options.mergeMethod.rawValue) is not allowed here)"
            return Self.mergeOutcome(auto: auto, n: n, state: await mergeState(n, repo), note: note)
        case .disableAutoMerge:
            _ = try await gh.run(["pr", "merge", n, "-R", repo, "--disable-auto"])
            return .done("Auto-merge cancelled for #\(n)")
        }
    }

    /// Reads the PR back after a merge command. Nil if that fails; the command itself already succeeded.
    func mergeState(_ n: String, _ repo: String) async -> MergeState? {
        guard let data = try? await gh.run(["pr", "view", n, "-R", repo, "--json", "state,isInMergeQueue,autoMergeRequest"]) else {
            return nil
        }
        return try? JSONDecoder().decode(MergeState.self, from: data)
    }

    static func mergeOutcome(auto: Bool, n: String, state: MergeState?, note: String) -> ActionOutcome {
        guard let state else {
            // The command succeeded but we could not read the result back, so do not claim more than that.
            return .done((auto ? "Auto-merge requested for #\(n)" : "Merge requested for #\(n)") + "; result not confirmed" + note)
        }
        if state.state == "MERGED" { return .done("Merged #\(n)" + (auto ? " (requirements were already met)" : "") + note) }
        if state.isInMergeQueue == true { return .queued("Added #\(n) to the merge queue" + note) }
        if state.autoMergeRequest != nil {
            let text = "Auto-merge enabled for #\(n)" + note
            return auto ? .done(text) : .queued(text + "; it will merge when requirements are met")
        }
        if state.state == "CLOSED" { return .skipped("#\(n) was closed instead of merged") }
        return .queued("Merge of #\(n) accepted but it is still open")
    }

    static func headMoved(_ n: String) -> String { "#\(n) changed since it was loaded; refresh and review it again" }

    static func withRetry(sleep: @Sendable (Duration) async -> Void, _ op: @Sendable () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do { return try await op() } catch let err as GhError {
                guard err.stderr.contains("base branch was modified"), attempt < retryDelays.count else { throw err }
                await sleep(retryDelays[attempt])
                attempt += 1
            }
        }
    }

    public func comment(_ body: String, on pr: PR) async throws {
        _ = try await gh.run(["pr", "comment", String(pr.number), "-R", pr.repo.fullName, "--body", body])
    }

    public func rerunCheck(_ check: CheckRun, in repo: RepoId) async throws {
        guard let id = check.databaseId else { return }
        _ = try await gh.run(["api", "-X", "POST", "repos/\(repo.fullName)/check-runs/\(id)/rerequest"])
    }
}

public enum Dependabot {
    /// The comment that issues `command` to Dependabot.
    public static func comment(_ command: String) -> String { "@dependabot \(command)" }

    public static let commands: [(key: String, label: String, comment: String)] = [
        ("r", "Rebase", "rebase"), ("e", "Recreate", "recreate"), ("m", "Merge", "merge"),
        ("s", "Squash and merge", "squash and merge"), ("c", "Cancel merge", "cancel merge"),
        ("x", "Close", "close"), ("o", "Reopen", "reopen"),
        ("i", "Ignore this dependency", "ignore this dependency"),
        ("I", "Ignore this major version", "ignore this major version"),
        ("j", "Ignore this minor version", "ignore this minor version"),
        ("k", "Ignore this patch version", "ignore this patch version"),
        ("u", "Unignore", "unignore *"),
    ]
}
