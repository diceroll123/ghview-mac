import Foundation
import Testing
@testable import GHCore

@Test func parsesRealDependabotDiff() throws {
    let url = try #require(Bundle.module.url(forResource: "dependabot", withExtension: "diff", subdirectory: "Fixtures"))
    let files = DiffParser.parse(try String(contentsOf: url, encoding: .utf8))
    #expect(files.count == 1)
    let f = files[0]
    #expect(f.displayPath == "Cargo.lock")
    #expect(f.status == .modified)
    #expect(f.additions == 2 && f.deletions == 2)
    let h = try #require(f.hunks.first)
    #expect(h.section == "dependencies = [")
    #expect(h.lines.first?.oldNumber == 884 && h.lines.first?.newNumber == 884)
    let removed = h.lines.filter { $0.kind == .removed }
    #expect(removed.first?.text == #"version = "1.48.0""#)
    #expect(removed.first?.oldNumber == 887 && removed.first?.newNumber == nil)
    let added = h.lines.first { $0.kind == .added }
    #expect(added?.newNumber == 887 && added?.oldNumber == nil)
}

@Test func parsesStatusesAndEdgeCases() {
    let diff = """
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..e69de29
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +one
    +two
    diff --git a/gone.txt b/gone.txt
    deleted file mode 100644
    --- a/gone.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    \\ No newline at end of file
    diff --git a/old name.txt b/new name.txt
    similarity index 90%
    rename from old name.txt
    rename to new name.txt
    --- a/old name.txt
    +++ b/new name.txt
    @@ -1,3 +1,3 @@
     keep

    -a
    +b
    diff --git a/img.png b/img.png
    Binary files a/img.png and b/img.png differ
    diff --git a/with space.txt b/with space.txt
    index 1..2 100644
    --- a/with space.txt
    +++ b/with space.txt
    @@ -1 +1 @@
    -x
    +y

    """
    let files = DiffParser.parse(diff)
    #expect(files.map(\.status) == [.added, .deleted, .renamed, .modified, .modified])
    #expect(files.map(\.isBinary) == [false, false, false, true, false])   // binary is separate from what happened to the file
    #expect(files[0].displayPath == "new.txt" && files[0].additions == 2)
    #expect(files[1].displayPath == "gone.txt" && files[1].deletions == 1)
    #expect(files[1].hunks[0].lines.last?.kind == .note)
    #expect(files[2].displayPath == "old name.txt -> new name.txt")
    // blank context line keeps numbering aligned
    #expect(files[2].hunks[0].lines.map(\.newNumber) == [1, 2, nil, 3])
    #expect(files[2].hunks[0].lines.map(\.oldNumber) == [1, 2, 3, nil])
    #expect(files[3].hunks.isEmpty)
    #expect(files[4].displayPath == "with space.txt")
    #expect(files[4].hunks[0].lines.count == 2)
}

@Test func fetcherDiffsTheListedHeadCommitAgainstTheBase() async throws {
    let seen = LockedBox<[String]>([])
    let gh = MockGh { args in seen.set(args); return Data("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n".utf8) }
    let files = try await DiffFetcher.fetch(samplePR(7), gh: gh)
    #expect(seen.get() == ["api", "-H", "Accept: application/vnd.github.diff", "repos/o/r/compare/main...s"])
    #expect(files.count == 1 && files[0].additions == 1)
}

@Test func diffIdentityChangesWithTheHeadOrTheBase() {
    var pr = samplePR(7)
    let original = DiffFetcher.identity(pr)
    pr.baseRef = "release/1.0"                                   // retargeted, head untouched
    #expect(DiffFetcher.identity(pr) != original)
    #expect(DiffFetcher.comparePath(pr) == "repos/o/r/compare/release/1.0...s")
    pr.baseRef = "main"
    pr.headSha = "newer"
    #expect(DiffFetcher.identity(pr) != original)
    pr.baseRef = "odd#name"
    #expect(DiffFetcher.comparePath(pr) == "repos/o/r/compare/odd%23name...newer")
}

// MARK: git's quoted paths and other header forms

@Test func unquotesGitEscapes() {
    #expect(DiffParser.unquote(#""foo\tbar.swift""#) == "foo\tbar.swift")
    #expect(DiffParser.unquote(#""say \"hi\".txt""#) == #"say "hi".txt"#)
    #expect(DiffParser.unquote(#""back\\slash""#) == #"back\slash"#)
    #expect(DiffParser.unquote(#""caf\303\251.swift""#) == "caf\u{e9}.swift")              // UTF-8 bytes as octal
    #expect(DiffParser.unquote(#""\346\227\245\346\234\254.md""#) == "\u{65e5}\u{672c}.md")
    #expect(DiffParser.unquote(#""line\nbreak""#) == "line\nbreak")
    #expect(DiffParser.unquote("plain/path.txt") == "plain/path.txt")
    #expect(DiffParser.unquote(#""unterminated"#) == #""unterminated"#)
}

@Test func aQuotedPathMapsToItsRealFilenameAndLanguage() {
    let diff = """
    diff --git "a/src/foo\\tbar.swift" "b/src/foo\\tbar.swift"
    index 1..2 100644
    --- "a/src/foo\\tbar.swift"
    +++ "b/src/foo\\tbar.swift"
    @@ -1 +1 @@
    -a
    +b
    """
    let f = DiffParser.parse(diff)
    #expect(f.count == 1)
    #expect(f[0].oldPath == "src/foo\tbar.swift" && f[0].newPath == "src/foo\tbar.swift")
    #expect(!f[0].displayPath.contains("\"") && !f[0].displayPath.hasPrefix("b/"))
    #expect(LanguageDetector.language(forPath: f[0].newPath) == LanguageDetector.language(forPath: "x.swift"))
    #expect(f[0].additions == 1 && f[0].deletions == 1)
}

@Test func nonAsciiAndMixedQuotingInHeaders() {
    let diff = """
    diff --git a/plain.txt "b/caf\\303\\251.txt"
    similarity index 80%
    rename from plain.txt
    rename to "caf\\303\\251.txt"
    """
    let f = DiffParser.parse(diff)
    #expect(f[0].status == .renamed)
    #expect(f[0].oldPath == "plain.txt" && f[0].newPath == "caf\u{e9}.txt")
    #expect(DiffParser.paths(fromHeader: #"a/with space.txt "b/new\tname.txt""#) == ("with space.txt", "new\tname.txt"))
    #expect(DiffParser.paths(fromHeader: "a/x y.txt b/x y.txt") == ("x y.txt", "x y.txt"))
}

@Test func copiesModeOnlyChangesAndBinaryAdditionsKeepTheirKinds() {
    let diff = """
    diff --git a/orig.txt b/dup.txt
    similarity index 100%
    copy from orig.txt
    copy to dup.txt
    diff --git a/run.sh b/run.sh
    old mode 100644
    new mode 100755
    diff --git a/new.png b/new.png
    new file mode 100644
    index 0000000..abc
    Binary files /dev/null and b/new.png differ
    diff --git a/old.png b/old.png
    deleted file mode 100644
    GIT binary patch
    literal 0
    """
    let f = DiffParser.parse(diff)
    #expect(f.map(\.status) == [.copied, .modified, .added, .deleted])
    #expect(f[0].displayPath == "orig.txt -> dup.txt")
    #expect(f[1].modeChange == "100644 -> 100755" && f[1].hunks.isEmpty && f[1].additions == 0)
    #expect(f.map(\.isBinary) == [false, false, true, true])
    #expect(f[2].displayPath == "new.png" && f[3].displayPath == "old.png")
}

@Test func noFinalNewlineMarkersAreNotesOnTheRightLine() {
    let diff = """
    diff --git a/a.txt b/a.txt
    --- a/a.txt
    +++ b/a.txt
    @@ -1 +1 @@
    -old
    \\ No newline at end of file
    +new
    \\ No newline at end of file
    """
    let lines = DiffParser.parse(diff)[0].hunks[0].lines
    #expect(lines.map(\.kind) == [.removed, .note, .added, .note])
    #expect(lines.filter { $0.kind != .note }.count == 2)
}

@Test func aDiffFallsBackToTheCurrentOneWhenThePinnedComparisonIsGone() async throws {
    let seen = LockedBox<[[String]]>([])
    let gh = MockGh { args in
        seen.update { $0 += [args] }
        if args.first == "api" { throw GhError(args: args, status: 1, stderr: "gh: Not Found (HTTP 404)") }
        return Data("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n".utf8)
    }
    let result = try await DiffFetcher.fetchResult(samplePR(7), gh: gh)
    #expect(result.usedCurrentDiff && result.files.count == 1)
    #expect(seen.get().map { $0[0] } == ["api", "pr"])
    #expect(seen.get()[1] == ["pr", "diff", "7", "-R", "o/r", "--color=never"])
}

@Test func whenBothDiffsFailTheMessageCarriesBothReasons() async {
    let gh = MockGh { args in throw GhError(args: args, status: 1, stderr: args.first == "api" ? "HTTP 404" : "could not find pull request") }
    do {
        _ = try await DiffFetcher.fetchResult(samplePR(7), gh: gh)
        Issue.record("expected an error")
    } catch let e as GhError {
        #expect(e.localizedDescription.contains("could not find pull request") && e.localizedDescription.contains("HTTP 404"))
    } catch { Issue.record("wrong error \(error)") }
}

@Test func aTimedOutPinnedDiffIsNotRetriedThroughAnotherRoute() async {
    let calls = LockedBox<Int>(0)
    let gh = MockGh { args in calls.update { $0 += 1 }; throw GhError(args: args, status: 124, stderr: "did not finish") }
    await #expect(throws: GhError.self) { _ = try await DiffFetcher.fetchResult(samplePR(7), gh: gh) }
    #expect(calls.get() == 1)
}
