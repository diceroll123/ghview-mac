import Foundation

/// Maps a file path to a highlight.js style language id, or nil if it should stay plain.
public enum LanguageDetector {
    static let byExtension: [String: String] = [
        "swift": "swift", "rs": "rust", "py": "python", "pyi": "python", "rb": "ruby", "go": "go",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "json": "json", "jsonc": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "cfg": "ini", "lock": "ini",
        "md": "markdown", "markdown": "markdown", "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml", "svg": "xml",
        "css": "css", "scss": "scss", "sass": "scss", "less": "less",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "scala": "scala", "groovy": "groovy", "gradle": "groovy",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "m": "objectivec", "mm": "objectivec", "cs": "csharp", "php": "php", "lua": "lua", "pl": "perl",
        "sql": "sql", "dart": "dart", "r": "r", "ex": "elixir", "exs": "elixir", "erl": "erlang",
        "hs": "haskell", "ml": "ocaml", "clj": "clojure", "vue": "xml", "diff": "diff", "patch": "diff",
        "tf": "hcl", "proto": "protobuf", "graphql": "graphql", "gql": "graphql", "zig": "zig", "nim": "nim",
    ]

    static let byFilename: [String: String] = [
        "dockerfile": "dockerfile", "makefile": "makefile", "gnumakefile": "makefile", "justfile": "makefile",
        "cmakelists.txt": "cmake", "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby",
        "package.swift": "swift", ".gitignore": "bash", ".zshrc": "bash", ".bashrc": "bash",
    ]

    public static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let l = byFilename[name] { return l }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : byExtension[ext]
    }
}

public extension DiffHunk {
    /// The hunk as two code streams so each side can be highlighted as contiguous source.
    /// `new` is context + added lines, `old` is context + removed lines; each entry keeps its line id.
    func sideStreams() -> (new: [(id: Int, text: String)], old: [(id: Int, text: String)]) {
        var new: [(Int, String)] = [], old: [(Int, String)] = []
        for l in lines {
            switch l.kind {
            case .context: new.append((l.id, l.text)); old.append((l.id, l.text))
            case .added: new.append((l.id, l.text))
            case .removed: old.append((l.id, l.text))
            case .note: break
            }
        }
        return (new, old)
    }
}
