import AppKit
import NewlineCore

/// Paint code per visual line, avoiding NSTextView's full line-height rectangles.
final class CodeLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, glyphsToShow.length > 0 {
            let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            storage.enumerateAttribute(.newlineInlineCode, in: visible) { value, range, _ in
                guard value as? Bool == true else { return }
                let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                self.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, container, line, _ in
                    let fragment = NSIntersectionRange(line, glyphs)
                    guard fragment.length > 0 else { return }
                    var rect = self.boundingRect(forGlyphRange: fragment, in: container)
                    let character = self.characterIndexForGlyph(at: fragment.location)
                    let font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont
                        ?? NSFont.monospacedSystemFont(ofSize: 14.4, weight: .regular)
                    // Center around the visible letters, not the line box (which includes leading).
                    let baselineOffset = (storage.attribute(.baselineOffset, at: character, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                    let baseline = lineRect.minY + self.location(forGlyphAt: fragment.location).y - baselineOffset
                    let padding = font.pointSize * 0.18
                    rect.origin.y = baseline - font.capHeight - padding
                    rect.size.height = font.capHeight - font.descender + padding * 2
                    rect = rect.insetBy(dx: -3, dy: 0).offsetBy(dx: origin.x, dy: origin.y)
                    let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
                    NSColor.labelColor.withAlphaComponent(0.055).setFill()
                    path.fill()
                    NSColor.labelColor.withAlphaComponent(0.065).setStroke()
                    path.lineWidth = 0.5
                    path.stroke()
                }
            }
        }
        // Native selection and search highlighting stay on top.
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
