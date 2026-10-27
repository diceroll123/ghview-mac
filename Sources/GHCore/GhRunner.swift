import Foundation

public struct GhError: Error, LocalizedError, Equatable {
    public let args: [String]
    public let status: Int32
    public let stderr: String
    /// `gh api graphql` still prints the response body when only part of a query failed.
    public let stdout: Data

    public init(args: [String], status: Int32, stderr: String, stdout: Data = Data()) {
        self.args = args
        self.status = status
        self.stderr = stderr
        self.stdout = stdout
    }

    public var errorDescription: String? {
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "gh exited with status \(status)" : msg
    }
}

/// Abstraction over the `gh` binary so tests can mock it.
public protocol GhRunner: Sendable {
    func run(_ args: [String], stdin: Data?, cwd: URL?) async throws -> Data
}

public extension GhRunner {
    func run(_ args: [String]) async throws -> Data {
        try await run(args, stdin: nil, cwd: nil)
    }
}

/// Limits how many `gh` processes run at once, and holds new ones back for a while after GitHub asks us to slow down.
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UInt64, cont: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0
    private var notBefore: ContinuousClock.Instant?

    public init(limit: Int) { available = max(1, limit) }

    /// Waits for a free slot (and for any backoff to end). Throws `CancellationError` if the task is cancelled
    /// while waiting, without taking a slot.
    public func acquire() async throws {
        while let until = notBefore, until > .now {
            try await Task.sleep(until: until)
        }
        if available > 0 { available -= 1; return }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: CancellationError()); return }
                waiters.append((id, c))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(throwing: CancellationError())
    }

    public func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().cont.resume() }
    }

    /// New work waits until `duration` from now has passed. Longer backoffs win over shorter ones.
    public func backoff(for duration: Duration) {
        let until = ContinuousClock.now + duration
        if notBefore.map({ until > $0 }) ?? true { notBefore = until }
    }
}

/// Lets the cancellation and timeout paths reach a running child process.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var cancelled = false
    private(set) var timedOut = false

    func attach(_ p: Process) {
        lock.lock(); process = p; let stop = cancelled || timedOut; lock.unlock()
        if stop { terminate(p) }
    }

    func cancel() { stop { self.cancelled = true } }
    func timeout() { stop { self.timedOut = true } }

    private func stop(_ mark: () -> Void) {
        lock.lock(); mark(); let p = process; lock.unlock()
        if let p { terminate(p) }
    }

    /// SIGTERM, then SIGKILL if the child is still there two seconds later.
    private func terminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

public struct GhCLI: GhRunner {
    public let executable: URL
    /// A command that has not finished by then is killed and reported as timed out.
    public let timeout: Duration
    public let limiter: AsyncSemaphore
    /// How long new commands are held back after GitHub reports a rate limit.
    public let rateLimitBackoff: Duration

    public init(executable: URL? = nil, timeout: Duration = .seconds(120), maxConcurrent: Int = 8,
                rateLimitBackoff: Duration = .seconds(30)) throws {
        if let executable {
            self.executable = executable
        } else if let found = GhCLI.locate() {
            self.executable = found
        } else {
            throw GhError(args: [], status: 127, stderr: "gh not found; install it from https://cli.github.com")
        }
        self.timeout = timeout
        self.limiter = AsyncSemaphore(limit: maxConcurrent)
        self.rateLimitBackoff = rateLimitBackoff
        signal(SIGPIPE, SIG_IGN) // a child that exits without reading stdin must not take the app down
    }

    /// GUI apps do not inherit the shell PATH, so probe common locations.
    static func locate() -> URL? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func isRateLimit(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("secondary rate limit") || s.contains("rate limit exceeded") || s.contains("abuse detection")
    }

    public func run(_ args: [String], stdin: Data?, cwd: URL?) async throws -> Data {
        try await limiter.acquire()
        do {
            let data = try await execute(args, stdin: stdin, cwd: cwd)
            await limiter.release()
            return data
        } catch {
            await limiter.release()
            if let err = error as? GhError, Self.isRateLimit(err.stderr) { await limiter.backoff(for: rateLimitBackoff) }
            throw error
        }
    }

    private func execute(_ args: [String], stdin: Data?, cwd: URL?) async throws -> Data {
        let exe = executable, limit = timeout
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try Self.runBlocking(exe, args, stdin: stdin, cwd: cwd, timeout: limit, running: running)
            }.value
        } onCancel: {
            running.cancel()
        }
    }

    private static func runBlocking(_ exe: URL, _ args: [String], stdin: Data?, cwd: URL?, timeout: Duration,
                                    running: RunningProcess) throws -> Data {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["GH_PAGER"] = ""
        env["NO_COLOR"] = "1"
        env["GH_PROMPT_DISABLED"] = "1"
        process.environment = env

        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        try process.run()
        running.attach(process)

        // Stdin, stdout and stderr are all serviced at once: a child that fills a pipe before it reads (or
        // writes before it has read all of its input) would otherwise deadlock against us.
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let collected = Collected()
        if let stdin {
            group.enter()
            queue.async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
                group.leave()
            }
        }
        group.enter()
        queue.async { collected.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        queue.async { collected.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let timer = DispatchWorkItem { running.timeout() }
        queue.asyncAfter(deadline: .now() + seconds, execute: timer)

        group.wait()
        process.waitUntilExit()
        timer.cancel()

        if running.cancelled { throw CancellationError() }
        if running.timedOut {
            throw GhError(args: args, status: 124, stderr: "gh did not finish within \(Int(seconds)) seconds and was stopped",
                          stdout: collected.out)
        }
        guard process.terminationStatus == 0 else {
            throw GhError(args: args, status: process.terminationStatus,
                          stderr: String(decoding: collected.err, as: UTF8.self), stdout: collected.out)
        }
        return collected.out
    }

    private final class Collected: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}
