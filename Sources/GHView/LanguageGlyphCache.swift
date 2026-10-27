import AppKit
import GHCore

/// Decodes each language's embedded SVG once. AppKit renders SVG natively, so there is no renderer to maintain.
@MainActor
enum LanguageGlyphCache {
    private static var images: [String: NSImage] = [:]

    static func image(for glyph: LanguageBadge.Glyph) -> NSImage? {
        if let cached = images[glyph.slug] { return cached }
        guard let image = NSImage(data: Data(glyph.svg.utf8)) else { return nil }
        image.isTemplate = true
        images[glyph.slug] = image
        return image
    }
}
