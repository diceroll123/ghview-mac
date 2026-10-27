import Foundation

/// Short monochrome labels for GitHub's `primaryLanguage` names, used as colorless language icons.
public enum LanguageBadge {
    static let codes: [String: String] = [
        "python": "Py", "rust": "Rs", "swift": "Sw", "typescript": "TS", "javascript": "JS", "shell": "sh",
        "lua": "Lu", "css": "CSS", "scss": "Sc", "html": "<>", "java": "Jv", "kotlin": "Kt", "vue": "Vue",
        "go": "Go", "ruby": "Rb", "php": "php", "c": "C", "c++": "C++", "c#": "C#", "objective-c": "ObjC",
        "dart": "Dt", "elixir": "Ex", "erlang": "Er", "haskell": "Hs", "scala": "Sca", "r": "R", "perl": "Pl",
        "powershell": "PS", "dockerfile": "Dk", "makefile": "Mk", "nix": "Nix", "zig": "Zig", "hcl": "HCL",
        "jupyter notebook": "Nb", "vim script": "Vim", "vim l": "Vim", "tex": "TeX", "markdown": "Md",
        "svelte": "Sv", "astro": "As", "clojure": "Clj", "ocaml": "ML", "julia": "Jl", "groovy": "Gv",
        "assembly": "Asm", "sql": "SQL", "plpgsql": "SQL", "batchfile": "Bat", "gdscript": "GD", "cmake": "CM",
    ]

    /// A language's logo: the optimized SVG and the Simple Icons slug it came from (a stable cache key).
    public struct Glyph: Sendable, Equatable {
        public let slug: String
        public let svg: String
    }

    /// The logo for a GitHub language name, or nil when there is no faithful one (Java, C# and others whose
    /// logos are not in Simple Icons keep a text badge instead of a misleading stand-in).
    public static func glyph(for language: String) -> Glyph? {
        let key = language.trimmingCharacters(in: .whitespaces).lowercased()
        guard let slug = LanguageIconData.slugs[key], let svg = LanguageIconData.svgs[slug] else { return nil }
        return Glyph(slug: slug, svg: svg)
    }

    /// At most four characters so it fits a small badge. Unknown languages fall back to their first two letters.
    public static func code(for language: String) -> String {
        let name = language.trimmingCharacters(in: .whitespaces)
        if let known = codes[name.lowercased()] { return known }
        let letters = name.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return "?" }
        return String(letters.prefix(2)).capitalized
    }
}
