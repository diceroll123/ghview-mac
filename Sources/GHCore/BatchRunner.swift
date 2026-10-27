import Foundation

public struct BatchSummary: Sendable, Equatable {
    public var done: [String] = []
    /// The human-readable outcome of each success, e.g. "Auto-merge enabled for #12".
    public var doneMessages: [String] = []
    public var skipped: [String] = []
    /// Accepted by GitHub but not finished: in a merge queue, or waiting for auto-merge.
    public var queued: [String] = []
    public var queuedMessages: [String] = []
    public var queuedIDs: [PrId] = []
    public var failed: [String] = []
    /// The same outcomes by PR identity, so a caller can keep just the failures selected for a retry.
    public var doneIDs: [PrId] = []
    public var skippedIDs: [PrId] = []
    public var failedIDs: [PrId] = []

    public var message: String {
        var parts: [String] = []
        if !done.isEmpty { parts.append("\(done.count) done") }
        if !queued.isEmpty { parts.append("\(queued.count) queued") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
    }
}

public enum BatchRunner {
    /// Runs the action for every PR concurrently (merges into one base are serialized by `PrActions`).
    /// `progress` is called with the number of finished PRs after each one completes.
    public static func run(_ action: PrAction, on prs: [PR], actions: PrActions, options: ActionOptions,
                           progress: (@Sendable (Int) -> Void)? = nil,
                           context: @Sendable (PR) -> ActionContext) async -> BatchSummary {
        let pairs = prs.map { ($0, context($0)) }
        return await withTaskGroup(of: (PR, Result<ActionOutcome, Error>).self) { group in
            for (pr, ctx) in pairs {
                group.addTask {
                    do { return (pr, .success(try await actions.perform(action, pr: pr, options: options, ctx: ctx))) }
                    catch { return (pr, .failure(error)) }
                }
            }
            var summary = BatchSummary()
            var finished = 0
            for await (pr, result) in group {
                finished += 1
                progress?(finished)
                let label = "\(pr.repo.fullName)#\(pr.number)"
                switch result {
                case .success(.done(let message)): summary.done.append(label); summary.doneMessages.append(message); summary.doneIDs.append(pr.id)
                case .success(.queued(let message)): summary.queued.append(label); summary.queuedMessages.append(message); summary.queuedIDs.append(pr.id)
                case .success(.skipped(let why)): summary.skipped.append("\(label): \(why)"); summary.skippedIDs.append(pr.id)
                case .failure(let err):
                    // A cancelled command may already have reached GitHub, so its state is unknown, not unchanged.
                    let why = err is CancellationError ? "interrupted; refresh to see whether it went through" : err.localizedDescription
                    summary.failed.append("\(label): \(why)"); summary.failedIDs.append(pr.id)
                }
            }
            return summary
        }
    }

    /// Posts `body` as a comment on every PR, collecting each failure instead of discarding it.
    public static func comment(_ body: String, on prs: [PR], actions: PrActions) async -> BatchSummary {
        await withTaskGroup(of: (PR, Error?).self) { group in
            for pr in prs {
                group.addTask {
                    do { try await actions.comment(body, on: pr); return (pr, nil) } catch { return (pr, error) }
                }
            }
            var summary = BatchSummary()
            for await (pr, err) in group {
                let label = "\(pr.repo.fullName)#\(pr.number)"
                if let err { summary.failed.append("\(label): \(err.localizedDescription)"); summary.failedIDs.append(pr.id) }
                else { summary.done.append(label); summary.doneIDs.append(pr.id) }
            }
            return summary
        }
    }
}
