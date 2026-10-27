import Foundation
import Testing
@testable import GHCore

@Test func convertsHTMLAndHeadings() {
    let raw = """
    ## Title here
    Bumps <a href="https://x.dev/a">pkg</a> from <code>1.0</code> to 2.0.<br>
    <details>
    <summary>Commits</summary>
    <ul>
    <li><code>abc</code> fix &amp; stuff</li>
    </ul>
    </details>
    <!-- hidden -->
    """
    let blocks = MarkdownLite.blocks(raw)
    #expect(blocks.count == 1)
    guard case .text(let t) = blocks[0] else { Issue.record("expected text"); return }
    #expect(t.contains("**Title here**"))
    #expect(t.contains("[pkg](https://x.dev/a)"))
    #expect(t.contains("`1.0`"))
    #expect(t.contains("**Commits**"))
    #expect(t.contains("- `abc` fix & stuff"))
    #expect(!t.contains("<") && !t.contains("hidden"))
}

@Test func keepsFencedCodeVerbatim() {
    let raw = "before\n```swift\nlet a = <b>1</b>\n\n\n\nx\n```\nafter\n```\nunterminated"
    #expect(MarkdownLite.blocks(raw) == [
        .text("before"), .code("let a = <b>1</b>\n\n\n\nx"), .text("after"), .code("unterminated"),
    ])
}

@Test func realDependabotBodyHasNoRawTags() throws {
    struct Env: Decodable { var data: D; struct D: Decodable { var repository: R }; struct R: Decodable { var pullRequest: P }; struct P: Decodable { var body: String } }
    let env = try JSONDecoder().decode(Env.self, from: fixture("activity"))
    let blocks = MarkdownLite.blocks(env.data.repository.pullRequest.body)
    #expect(!blocks.isEmpty)
    for case .text(let t) in blocks { #expect(!t.contains("<details>") && !t.contains("<summary>") && !t.contains("<li>")) }
}

@Test func badgeLinkDoesNotLeaveBlankGap() throws {
    let url = try #require(Bundle.module.url(forResource: "codspeed_comment", withExtension: "md", subdirectory: "Fixtures"))
    let blocks = MarkdownLite.blocks(try String(contentsOf: url, encoding: .utf8))
    // content, rule, footer text: nothing blank or whitespace-only
    #expect(blocks.contains(.rule))
    guard case .text(let last) = try #require(blocks.last) else { Issue.record("expected trailing text"); return }
    #expect(last.hasSuffix("[Open in CodSpeed](https://app.codspeed.io/diceroll123/pymermaider/branches/renovate%2Fnextjs-monorepo?utm_source=github&utm_medium=comment-v2&utm_content=button)"))
    #expect(!last.contains("<") && !last.contains("[\n") && !last.contains("[ ]"))
    for case .text(let t) in blocks { #expect(t == t.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

@Test func linkLabelsAreSqueezedAndEmptyLabelsUseTheURL() {
    #expect(MarkdownLite.convertLinks("<a href=\"u\">\n  a   b \n</a>") == "[a b](u)")
    #expect(MarkdownLite.convertLinks("<a href=\"https://x\"> \n </a>") == "<https://x>")
    #expect(MarkdownLite.blocks("a\n\n---\n\nb") == [.text("a"), .rule, .text("b")])
    #expect(MarkdownLite.blocks("- item\n- item") == [.text("- item\n- item")]) // list dashes are not rules
}

// MARK: code is literal

private func onlyText(_ raw: String) -> String {
    guard case .text(let t)? = MarkdownLite.blocks(raw).first else { return "" }
    return t
}

@Test func inlineCodeKeepsGenericsAndTags() {
    #expect(onlyText("Use `Array<String>` here.") == "Use `Array<String>` here.")
    #expect(onlyText("JSX like `<Button onClick={go}>Go</Button>` and `<div/>` stay") == "JSX like `<Button onClick={go}>Go</Button>` and `<div/>` stay")
    #expect(onlyText("xml `<?xml version=\"1.0\"?>` and `<!-- not a comment -->`") == "xml `<?xml version=\"1.0\"?>` and `<!-- not a comment -->`")
    #expect(onlyText("entities in code stay `&lt;` literal but &lt;b&gt; outside decodes") == "entities in code stay `&lt;` literal but <b> outside decodes")
}

@Test func nestedAndMultiBacktickSpans() {
    #expect(onlyText("a ``code with ` tick`` b") == "a ``code with ` tick`` b")
    #expect(onlyText("``Map<String, `Int`>`` then <b>bold</b>") == "``Map<String, `Int`>`` then bold")
    #expect(onlyText("unmatched ` tick and <i>tag</i>") == "unmatched ` tick and tag")   // a lone backtick is literal
    #expect(onlyText(#"escaped \`<b>x</b>\` ticks"#) == #"escaped \`x\` ticks"#)
}

@Test func htmlCodeElementsKeepTheirContents() {
    #expect(onlyText("<code>List<int></code> and <code>a &amp;&amp; b</code>") == "`List<int>` and `a && b`")
    #expect(onlyText("write `<code>x</code>` for code") == "write `<code>x</code>` for code")   // a mention of the tag is not the tag
}

@Test func fencesTrackTheirDelimiterAndLength() {
    // A longer fence is not closed by a shorter one, so a ``` block can sit inside ````.
    let nested = "````md\n```swift\nlet a = <b>1</b>\n```\n````\nafter"
    #expect(MarkdownLite.blocks(nested) == [.code("```swift\nlet a = <b>1</b>\n```"), .text("after")])
    // Tilde fences are fences, and a backtick line does not close a tilde one.
    #expect(MarkdownLite.blocks("~~~\n<i>x</i>\n```\n~~~\nend") == [.code("<i>x</i>\n```"), .text("end")])
    // A closing fence carries no info string; a line like ```js inside a block is content.
    #expect(MarkdownLite.blocks("```\nbody\n```js\nmore\n```") == [.code("body\n```js\nmore")])
    // Three backticks with a backtick after them are inline code, not a fence.
    #expect(MarkdownLite.blocks("```not a fence``` but <b>text</b>") == [.text("```not a fence``` but text")])
}
