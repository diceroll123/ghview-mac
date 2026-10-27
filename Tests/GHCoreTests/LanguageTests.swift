import Foundation
import Testing
@testable import GHCore

@Test func detectsLanguages() {
    #expect(LanguageDetector.language(forPath: "Sources/App/main.swift") == "swift")
    #expect(LanguageDetector.language(forPath: "src/lib.RS") == "rust")
    #expect(LanguageDetector.language(forPath: "Cargo.lock") == "ini")
    #expect(LanguageDetector.language(forPath: "deploy/Dockerfile") == "dockerfile")
    #expect(LanguageDetector.language(forPath: "justfile") == "makefile")
    #expect(LanguageDetector.language(forPath: "README") == nil)
    #expect(LanguageDetector.language(forPath: "data.unknownext") == nil)
}

@Test func hunkSideStreams() {
    let diff = """
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1,3 +1,3 @@
     let a = 1
    -let b = 2
    +let b = 3
     let c = 4
    """
    let h = DiffParser.parse(diff)[0].hunks[0]
    let s = h.sideStreams()
    #expect(s.new.map(\.text) == ["let a = 1", "let b = 3", "let c = 4"])
    #expect(s.old.map(\.text) == ["let a = 1", "let b = 2", "let c = 4"])
}

@Test func languageBadgeCodes() {
    // every language that appears in the author's real repos has an explicit code
    for (lang, code) in [("Python", "Py"), ("Rust", "Rs"), ("Swift", "Sw"), ("TypeScript", "TS"), ("JavaScript", "JS"),
                         ("Shell", "sh"), ("Lua", "Lu"), ("CSS", "CSS"), ("HTML", "<>"), ("Java", "Jv"), ("Kotlin", "Kt"), ("Vue", "Vue")] {
        #expect(LanguageBadge.code(for: lang) == code)
    }
    #expect(LanguageBadge.code(for: "C++") == "C++")
    #expect(LanguageBadge.code(for: "  python ") == "Py")
    #expect(LanguageBadge.code(for: "Brainfuck") == "Br")      // unknown: first two letters
    #expect(LanguageBadge.code(for: "Q#") == "Q")
    #expect(LanguageBadge.code(for: "???") == "?")
    #expect(LanguageBadge.codes.values.allSatisfy { $0.count <= 4 })
}

// MARK: language logos

@Test func logosExistForTheLanguagesInUse() {
    for lang in ["Python", "Rust", "Swift", "TypeScript", "JavaScript", "Shell", "Lua", "CSS", "HTML", "Kotlin", "Vue", "Go", "C", "C++"] {
        #expect(LanguageBadge.glyph(for: lang) != nil, "\(lang)")
    }
    #expect(LanguageBadge.glyph(for: "  python ")?.slug == "python")           // case and whitespace do not matter
    #expect(LanguageBadge.glyph(for: "Shell")?.slug == "gnubash")
    #expect(LanguageBadge.glyph(for: "SCSS")?.slug == "sass")
}

@Test func languagesWithoutAFaithfulLogoKeepTheTextBadge() {
    // Simple Icons has no logo for these, and nearby ones (.NET, Apple, GNU, MySQL, OpenJDK) would mislead
    for lang in ["Java", "C#", "Objective-C", "Makefile", "SQL", "PowerShell", "Assembly", "Batchfile", "Brainfuck", ""] {
        #expect(LanguageBadge.glyph(for: lang) == nil, "\(lang)")
    }
}

@Test func everyEmbeddedLogoIsAMinimalTemplateSVG() {
    #expect(!LanguageIconData.svgs.isEmpty)
    for (slug, svg) in LanguageIconData.svgs {
        #expect(svg.hasPrefix("<svg "), "\(slug)")
        #expect(svg.contains(#"xmlns="http://www.w3.org/2000/svg""#) && svg.contains(#"viewBox="0 0 24 24""#), "\(slug)")
        #expect(svg.contains("<path"), "\(slug)")
        #expect(!svg.contains("<title") && !svg.contains("width=") && !svg.contains("height=") && !svg.contains("role="), "\(slug)")
        #expect(!svg.contains("fill=") && !svg.contains("style="), "\(slug) must stay uncolored so it can be tinted")
    }
}

@Test func logoMapAndDataAgreeAndStayInBudget() {
    for (lang, slug) in LanguageIconData.slugs {
        #expect(LanguageIconData.svgs[slug] != nil, "\(lang) -> \(slug) has no SVG")
        #expect(lang == lang.lowercased())
    }
    #expect(Set(LanguageIconData.svgs.keys).isSubset(of: Set(LanguageIconData.slugs.values))) // no orphaned logos
    let bytes = LanguageIconData.svgs.values.reduce(0) { $0 + $1.utf8.count }
    #expect(bytes < 45_000, "icon data grew to \(bytes) bytes")
}
