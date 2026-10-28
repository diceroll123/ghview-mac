import Foundation
import Testing
@testable import GHCore

/// A shell script standing in for `gh`.
private func script(_ body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghview-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("gh")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

private func waitFor(_ condition: () -> Bool, seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Test func cancellingTheCallerStopsTheChildProcess() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pid-\(UUID().uuidString)")
    let exe = try script("echo $$ > \(dir.path)\nexec sleep 60")
    let gh = try GhCLI(executable: exe)
    let task = Task { try await gh.run(["x"]) }
    #expect(await waitFor { FileManager.default.fileExists(atPath: dir.path) && ((try? String(contentsOf: dir, encoding: .utf8))?.isEmpty == false) })
    let pid = Int32((try String(contentsOf: dir, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
    #expect(alive(pid))

    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await waitFor { !alive(pid) })                                 // the sleeping child really exited
}

@Test func aCommandThatNeverFinishesTimesOut() async throws {
    let gh = try GhCLI(executable: try script("exec sleep 60"), timeout: .milliseconds(300))
    let started = Date()
    do {
        _ = try await gh.run(["x"])
        Issue.record("expected a timeout")
    } catch let err as GhError {
        #expect(err.status == 124)
        #expect(err.localizedDescription.contains("did not finish"))
    }
    #expect(Date().timeIntervalSince(started) < 10)
}

@Test func largeStdoutAndStderrDoNotDeadlock() async throws {
    let gh = try GhCLI(executable: try script("head -c 3000000 /dev/zero >&2\nhead -c 3000000 /dev/zero"))
    let out = try await gh.run(["x"])
    #expect(out.count == 3_000_000)
}

@Test func aChildThatWritesBeforeReadingStdinDoesNotDeadlock() async throws {
    // It fills stderr (far past the pipe buffer) before it reads a byte of its 2 MB input.
    let gh = try GhCLI(executable: try script("head -c 1000000 /dev/zero >&2\ncat"))
    let input = Data(repeating: 7, count: 2_000_000)
    let out = try await gh.run(["x"], stdin: input, cwd: nil)
    #expect(out == input)
}

@Test func aChildThatIgnoresItsStdinDoesNotCrashTheApp() async throws {
    let gh = try GhCLI(executable: try script("echo done"))
    let out = try await gh.run(["x"], stdin: Data(repeating: 1, count: 5_000_000), cwd: nil)
    #expect(String(decoding: out, as: UTF8.self) == "done\n")
}

@Test func aTwoHundredItemBatchStaysWithinTheConcurrencyBudget() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
    let exe = try script("echo s >> \(log.path)\nsleep 0.05\necho e >> \(log.path)")
    let gh = try GhCLI(executable: exe, maxConcurrent: 4)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<200 { group.addTask { _ = try await gh.run(["x"]) } }
        try await group.waitForAll()
    }
    var running = 0, peak = 0, total = 0
    for line in try String(contentsOf: log, encoding: .utf8).split(separator: "\n") {
        if line == "s" { running += 1; total += 1; peak = max(peak, running) } else { running -= 1 }
    }
    #expect(total == 200)
    #expect(peak <= 4 && peak >= 2)
}

@Test func cancellingWhileQueuedNeverStartsTheProcess() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
    let exe = try script("echo s >> \(log.path)\nsleep 1")
    let gh = try GhCLI(executable: exe, maxConcurrent: 1)
    let first = Task { try await gh.run(["a"]) }
    #expect(await waitFor { FileManager.default.fileExists(atPath: log.path) })
    let queued = Task { try await gh.run(["b"]) }
    try await Task.sleep(for: .milliseconds(100))
    queued.cancel()
    await #expect(throws: CancellationError.self) { _ = try await queued.value }
    _ = try await first.value
    #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 1)
}

@Test func aRateLimitHoldsBackTheNextCommand() async throws {
    let flag = FileManager.default.temporaryDirectory.appendingPathComponent("flag-\(UUID().uuidString)")
    let exe = try script("""
    if [ ! -e \(flag.path) ]; then touch \(flag.path); echo "You have exceeded a secondary rate limit" >&2; exit 1; fi
    echo ok
    """)
    let gh = try GhCLI(executable: exe, rateLimitBackoff: .milliseconds(600))
    await #expect(throws: GhError.self) { _ = try await gh.run(["x"]) }
    let started = Date()
    let out = try await gh.run(["x"])
    #expect(String(decoding: out, as: UTF8.self) == "ok\n")
    #expect(Date().timeIntervalSince(started) >= 0.5)
}

@Test func aTransientGatewayErrorIsRetriedAndSucceeds() async throws {
    let flag = FileManager.default.temporaryDirectory.appendingPathComponent("flag-\(UUID().uuidString)")
    let exe = try script("""
    if [ ! -e \(flag.path) ]; then touch \(flag.path); echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; fi
    echo ok
    """)
    let gh = try GhCLI(executable: exe, maxTransientRetries: 2, transientRetryDelay: .milliseconds(10))
    let out = try await gh.run(["x"])
    #expect(String(decoding: out, as: UTF8.self) == "ok\n")           // succeeded on retry, caller saw no error
}

@Test func transientRetriesGiveUpAfterTheLimit() async throws {
    let exe = try script(#"echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1"#)
    let gh = try GhCLI(executable: exe, maxTransientRetries: 2, transientRetryDelay: .milliseconds(10))
    await #expect(throws: GhError.self) { _ = try await gh.run(["x"]) }
}

@Test func aNonGatewayErrorIsNeverRetried() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("log-\(UUID().uuidString)")
    let exe = try script("echo run >> \(log.path)\necho \"gh: Not Found (HTTP 404)\" >&2\nexit 1")
    let gh = try GhCLI(executable: exe, maxTransientRetries: 2, transientRetryDelay: .milliseconds(10))
    await #expect(throws: GhError.self) { _ = try await gh.run(["x"]) }
    #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 1)   // ran exactly once
}

@Test func theSemaphoreGrantsSlotsInOrderAndReleasesThem() async throws {
    let sem = AsyncSemaphore(limit: 1)
    try await sem.acquire()
    let order = LockedBox<[Int]>([])
    let a = Task { try await sem.acquire(); order.update { $0 += [1] }; await sem.release() }
    try await Task.sleep(for: .milliseconds(20))
    let b = Task { try await sem.acquire(); order.update { $0 += [2] }; await sem.release() }
    try await Task.sleep(for: .milliseconds(20))
    await sem.release()
    try await a.value; try await b.value
    #expect(order.get() == [1, 2])
}
