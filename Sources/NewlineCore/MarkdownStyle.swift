import AppKit

public extension NSAttributedString.Key {
    static let newlineBlock = Self("Newline.block")
    static let newlineHeading = Self("Newline.heading")
    static let newlineListLevel = Self("Newline.listLevel")
    static let newlineListKind = Self("Newline.listKind")
    static let newlineListNumber = Self("Newline.listNumber")
    static let newlineTaskChecked = Self("Newline.taskChecked")
    static let newlineInlineCode = Self("Newline.inlineCode")
    static let newlineImageSource = Self("Newline.imageSource")
    static let newlineImageAlt = Self("Newline.imageAlt")
    static let newlineImageTitle = Self("Newline.imageTitle")
    static let newlineFootnoteID = Self("Newline.footnoteID")
    static let newlineFootnoteReference = Self("Newline.footnoteReference")
    static let newlineFootnoteDefinition = Self("Newline.footnoteDefinition")
    static let newlineFootnoteOccurrence = Self("Newline.footnoteOccurrence")
    static let newlineBlockID = Self("Newline.blockID")
    static let newlineCodeLanguage = Self("Newline.codeLanguage")
    static let newlineGeneratedPrefix = Self("Newline.generatedPrefix")
    static let newlineTableRow = Self("Newline.tableRow")
    static let newlineTableColumn = Self("Newline.tableColumn")
    static let newlineTableHeader = Self("Newline.tableHeader")
    static let newlineTableAlignment = Self("Newline.tableAlignment")
    static let newlineBold = Self("Newline.bold")
    static let newlineItalic = Self("Newline.italic")
    static let newlineLinkTitle = Self("Newline.linkTitle")
    static let newlineQuoteLevel = Self("Newline.quoteLevel")
    static let newlineHardBreak = Self("Newline.hardBreak")
    static let newlineRawInline = Self("Newline.rawInline")
}

@MainActor
public enum MarkdownStyle {
    public static func attributes(fontSize: CGFloat, block: String = "paragraph", heading: Int = 0, level: Int = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        paragraph.paragraphSpacing = fontSize * 0.65
        var size = fontSize
        var font = NSFont.systemFont(ofSize: size)
        var foreground = NSColor.textColor
        if block == "heading" {
            let scales: [CGFloat] = [1.85, 1.5, 1.25, 1.12, 1.0, 0.94]
            size = fontSize * scales[max(0, min(5, heading - 1))]
            font = NSFont.systemFont(ofSize: size, weight: .semibold)
            paragraph.paragraphSpacingBefore = fontSize * 0.65
            paragraph.paragraphSpacing = fontSize * 0.55
            paragraph.lineHeightMultiple = 1.15
        } else if block == "code" || block == "raw" {
            font = NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
            paragraph.lineHeightMultiple = 1.25
            paragraph.paragraphSpacing = 2
            paragraph.headIndent = 12
            paragraph.firstLineHeadIndent = 12
        } else if block == "list" {
            paragraph.firstLineHeadIndent = CGFloat(level) * 24
            paragraph.headIndent = CGFloat(level) * 24 + 24
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            paragraph.paragraphSpacing = 4
        } else if block == "quote" {
            paragraph.firstLineHeadIndent = CGFloat(max(1, level)) * 22
            paragraph.headIndent = paragraph.firstLineHeadIndent
            foreground = .secondaryLabelColor
        } else if block == "footnote" {
            font = NSFont.systemFont(ofSize: fontSize * 0.88)
            paragraph.headIndent = 20
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
            paragraph.paragraphSpacing = 5
            foreground = .secondaryLabelColor
        } else if block == "rule" {
            foreground = .separatorColor
        }
        var result: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph,
            .newlineBlock: block, .newlineHeading: heading, .newlineListLevel: level
        ]
        if block == "quote" { result[.newlineQuoteLevel] = max(1, level) }
        if block == "code" { result[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12) }
        return result
    }

    public static func applyParagraph(_ block: String, to text: NSMutableAttributedString, range: NSRange, fontSize: CGFloat, heading: Int = 0, level: Int = 0) {
        guard text.length > 0, range.location < text.length else { return }
        let paragraphRange = (text.string as NSString).paragraphRange(for: NSRange(location: range.location, length: min(range.length, text.length - range.location)))
        text.addAttributes(attributes(fontSize: fontSize, block: block, heading: heading, level: level), range: paragraphRange)
        let copy = NSAttributedString(attributedString: text)
        copy.enumerateAttributes(in: paragraphRange) { attrs, range, _ in
            text.addAttribute(.font, value: font(for: attrs, size: fontSize), range: range)
            if attrs[.newlineInlineCode] as? Bool != true && block != "code" { text.removeAttribute(.backgroundColor, range: range) }
        }
    }

    public static func listPrefix(kind: String, number: Int = 1, checked: Bool = false) -> String {
        switch kind {
        case "ordered": return "\(number).\t"
        case "task": return checked ? "☑\t" : "☐\t"
        default: return "•\t"
        }
    }

    public static func font(for attributes: [NSAttributedString.Key: Any], size: CGFloat) -> NSFont {
        let block = attributes[.newlineBlock] as? String ?? "paragraph"
        let heading = attributes[.newlineHeading] as? Int ?? 0
        let base = Self.attributes(fontSize: size, block: block, heading: heading)[.font] as! NSFont
        let inlineCode = attributes[.newlineInlineCode] as? Bool == true
        var font = inlineCode ? NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular) : base
        var traits = NSFontManager.shared.traits(of: font)
        if attributes[.newlineBold] as? Bool == true || attributes[.newlineTableHeader] as? Bool == true { traits.insert(.boldFontMask) }
        if attributes[.newlineItalic] as? Bool == true { traits.insert(.italicFontMask) }
        font = NSFontManager.shared.convert(font, toHaveTrait: traits)
        if attributes[.newlineFootnoteReference] as? Bool == true {
            font = NSFontManager.shared.convert(font, toSize: size * 0.7)
        }
        return font
    }
}
