import AppKit
import cmark_gfm
import cmark_gfm_extensions

public struct MarkdownTextReplacement {
    public let range: NSRange
    public let replacementLength: Int

    /// Applies replacements expressed in the original text's UTF-16 coordinates.
    public static func adjusted(_ selection: NSRange, by edits: [MarkdownTextReplacement]) -> NSRange {
        func position(_ original: Int) -> Int {
            var value = original
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                if original >= NSMaxRange(edit.range) { value += edit.replacementLength - edit.range.length }
                else if original > edit.range.location { value += min(original - edit.range.location, edit.replacementLength) - (original - edit.range.location) }
            }
            return max(0, value)
        }
        let start = position(selection.location)
        return NSRange(location: start, length: max(0, position(NSMaxRange(selection)) - start))
    }
}

/// Converts ordinary Markdown to an editable native attributed string. Source snapshots
/// preserve the spelling of untouched blocks; only edited blocks are serialized anew.
@MainActor
public final class MarkdownCodec {
    private struct Snapshot {
        var source: String
        var suffix: String
        var signature: [SemanticRun]
    }
    private var snapshots: [String: Snapshot] = [:]
    private var originalSource = ""
    private var sourcePrefix = ""
    private var baseURL: URL?
    private var fontSize: CGFloat = 16
    private var footnoteNumbers: [String: Int] = [:]

    public init() {}

    public func render(_ source: String, baseURL: URL? = nil, fontSize: CGFloat = 16) -> NSAttributedString {
        snapshots.removeAll()
        self.originalSource = source
        self.baseURL = baseURL
        self.fontSize = fontSize
        self.sourcePrefix = ""
        footnoteNumbers.removeAll()
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(Int32(CMARK_OPT_FOOTNOTES | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE)) else {
            return NSAttributedString(string: source, attributes: MarkdownStyle.attributes(fontSize: fontSize))
        }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist", "autolink"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        // Mask front matter so its delimiters aren't interpreted as a rule/heading.
        let lines = sourceLines(source)
        let frontMatterEnd = frontMatterLineCount(lines)
        var parserSource = source
        if frontMatterEnd > 0 {
            parserSource = String(repeating: "\n", count: frontMatterEnd) + lines.dropFirst(frontMatterEnd).joined()
        }
        parserSource.utf8CString.withUnsafeBufferPointer { bytes in
            cmark_parser_feed(parser, bytes.baseAddress, bytes.count - 1)
        }
        guard let root = cmark_parser_finish(parser) else {
            return NSAttributedString(string: source, attributes: MarkdownStyle.attributes(fontSize: fontSize))
        }
        defer { cmark_node_free(root) }
        collectFootnoteNumbers(root)

        let result = NSMutableAttributedString(string: "")
        struct Piece { var start: Int; var end: Int; var node: UnsafeMutablePointer<cmark_node>? }
        var pieces: [Piece] = []
        if frontMatterEnd > 0 { pieces.append(Piece(start: 0, end: frontMatterEnd, node: nil)) }
        for node in children(root) {
            let start = max(0, Int(cmark_node_get_start_line(node)) - 1)
            let end = min(lines.count, Int(cmark_node_get_end_line(node)))
            guard end > start else { continue }
            pieces.append(Piece(start: start, end: end, node: node))
        }
        pieces.sort { $0.start < $1.start }
        var lineCursor = 0
        var previousID: String?
        func addGap(_ gap: String) {
            guard !gap.isEmpty else { return }
            if gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let id = previousID { snapshots[id]?.suffix += gap }
                else { sourcePrefix += gap }
            } else {
                // Link definitions, unused footnotes and unknown source are retained.
                let id = UUID().uuidString
                let raw = NSMutableAttributedString(string: gap.hasSuffix("\n") ? gap : gap + "\n", attributes: MarkdownStyle.attributes(fontSize: fontSize, block: "raw"))
                raw.addAttribute(.newlineBlockID, value: id, range: NSRange(location: 0, length: raw.length))
                snapshots[id] = Snapshot(source: gap, suffix: "", signature: semanticSignature(raw))
                result.append(raw)
                previousID = id
            }
        }
        for piece in pieces {
            guard piece.start >= lineCursor else { continue }
            addGap(lines[lineCursor..<piece.start].joined())
            let raw = lines[piece.start..<piece.end].joined()
            let id = UUID().uuidString
            let rendered = NSMutableAttributedString(string: "")
            if let node = piece.node {
                renderBlock(node, into: rendered, listLevel: 0, quoteLevel: 0)
            } else {
                rendered.append(NSAttributedString(string: raw.hasSuffix("\n") ? raw : raw + "\n", attributes: MarkdownStyle.attributes(fontSize: fontSize, block: "raw")))
            }
            if rendered.length == 0 {
                rendered.append(NSAttributedString(string: "\n", attributes: MarkdownStyle.attributes(fontSize: fontSize)))
            }
            rendered.addAttribute(.newlineBlockID, value: id, range: NSRange(location: 0, length: rendered.length))
            snapshots[id] = Snapshot(source: raw, suffix: "", signature: semanticSignature(rendered))
            result.append(rendered)
            previousID = id
            lineCursor = piece.end
        }
        addGap(lines.dropFirst(lineCursor).joined())
        return result
    }

    public func serialize(_ content: NSAttributedString) -> String {
        guard content.length > 0 else { return snapshots.isEmpty ? originalSource : "" }
        var result = sourcePrefix
        var seenIDs: Set<String> = []
        var previousWasCanonical = false
        var previousBlockKind: String?
        // Pasting a rich inline fragment can introduce another source ID inside a
        // paragraph. Source boundaries must stay at paragraph boundaries, otherwise
        // one inline insertion would accidentally become three Markdown paragraphs.
        let string = content.string as NSString
        var groups: [(id: String?, range: NSRange)] = []
        var cursor = 0
        while cursor < content.length {
            let range = string.paragraphRange(for: NSRange(location: cursor, length: 0))
            var id = content.attribute(.newlineBlockID, at: cursor, effectiveRange: nil) as? String
            if id == nil {
                content.enumerateAttribute(.newlineBlockID, in: range) { value, _, stop in
                    if let value = value as? String { id = value; stop.pointee = true }
                }
            }
            if groups.last?.id == id, !groups.isEmpty {
                groups[groups.count - 1].range.length += range.length
            } else { groups.append((id, range)) }
            cursor = NSMaxRange(range)
        }
        for (id, range) in groups {
            let blockKind = content.attribute(.newlineBlock, at: range.location, effectiveRange: nil) as? String ?? "paragraph"
            func separateCanonicalBlocks() {
                guard !result.isEmpty else { return }
                let required = previousBlockKind == "list" && blockKind == "list" ? 1 : 2
                let trailing = result.reversed().prefix(while: { $0 == "\n" }).count
                if trailing < required { result += String(repeating: "\n", count: required - trailing) }
            }
            if let id, let snapshot = snapshots[id], !seenIDs.contains(id) {
                if previousWasCanonical { separateCanonicalBlocks() }
                if semanticSignature(content, range: range, string: string) == snapshot.signature {
                    result += snapshot.source + snapshot.suffix
                    previousWasCanonical = false
                } else {
                    let written = serializeBlocks(content.attributedSubstring(from: range))
                    result += written
                    if !snapshot.suffix.isEmpty { result += snapshot.suffix }
                    else if !written.hasSuffix("\n\n") { result += "\n" }
                    previousWasCanonical = true
                }
                seenIDs.insert(id)
            } else {
                separateCanonicalBlocks()
                result += serializeBlocks(content.attributedSubstring(from: range))
                previousWasCanonical = true
            }
            previousBlockKind = content.attribute(.newlineBlock, at: NSMaxRange(range) - 1, effectiveRange: nil) as? String ?? "paragraph"
        }
        return result
    }

    public func restyle(_ content: NSMutableAttributedString, fontSize: CGFloat) {
        self.fontSize = fontSize
        guard content.length > 0 else { return }
        let copy = NSAttributedString(attributedString: content)
        copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length)) { attributes, range, _ in
            let block = attributes[.newlineBlock] as? String ?? "paragraph"
            let heading = attributes[.newlineHeading] as? Int ?? 0
            let level = block == "quote" ? attributes[.newlineQuoteLevel] as? Int ?? 1 : attributes[.newlineListLevel] as? Int ?? 0
            let style = MarkdownStyle.attributes(fontSize: fontSize, block: block, heading: heading, level: level)
            let paragraph = (style[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            if let original = attributes[.paragraphStyle] as? NSParagraphStyle, !original.textBlocks.isEmpty {
                paragraph.textBlocks = original.textBlocks
                paragraph.alignment = original.alignment
                paragraph.paragraphSpacing = 3
            }
            content.addAttributes([.font: MarkdownStyle.font(for: attributes, size: fontSize), .paragraphStyle: paragraph], range: range)
            if attributes[.newlineFootnoteReference] as? Bool == true {
                content.addAttribute(.baselineOffset, value: fontSize * 0.3, range: range)
            }
        }
    }

    /// Reorders visible numbers by first reference. Identifiers in the .md file are
    /// untouched, and unreferenced definitions remain available in the document.
    @discardableResult
    public func renumberFootnotes(in content: NSMutableAttributedString) -> [MarkdownTextReplacement] {
        guard content.length > 0 else { return [] }
        var numbers: [String: Int] = [:]
        var replacements: [(NSRange, String, [NSAttributedString.Key: Any])] = []
        var references: [(NSRange, String, [NSAttributedString.Key: Any])] = []
        var prefixes: [(NSRange, String, [NSAttributedString.Key: Any])] = []
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attrs, range, _ in
            guard let id = attrs[.newlineFootnoteID] as? String else { return }
            if attrs[.newlineFootnoteReference] as? Bool == true {
                if numbers[id] == nil { numbers[id] = numbers.count + 1 }
                if let previous = references.last, let occurrence = attrs[.newlineFootnoteOccurrence] as? String,
                   previous.2[.newlineFootnoteOccurrence] as? String == occurrence, NSMaxRange(previous.0) == range.location {
                    references[references.count - 1].0.length += range.length
                } else { references.append((range, id, attrs)) }
            } else if attrs[.newlineGeneratedPrefix] as? Bool == true,
                      attrs[.newlineBlock] as? String == "footnote" {
                prefixes.append((range, id, attrs))
            }
        }
        let original = content.string as NSString
        for (range, id, attrs) in references {
            let value = String(numbers[id] ?? 1)
            if original.substring(with: range) != value { replacements.append((range, value, attrs)) }
        }
        for (range, id, attrs) in prefixes {
            let value = numbers[id].map { "\($0).\t" } ?? "–\t"
            if original.substring(with: range) != value { replacements.append((range, value, attrs)) }
        }
        replacements.sort { $0.0.location > $1.0.location }
        for (range, value, attrs) in replacements {
            content.replaceCharacters(in: range, with: NSAttributedString(string: value, attributes: attrs))
        }
        return replacements.map { MarkdownTextReplacement(range: $0.0, replacementLength: $0.1.utf16.count) }
    }

    // MARK: Parsing

    private func children(_ node: UnsafeMutablePointer<cmark_node>) -> [UnsafeMutablePointer<cmark_node>] {
        var result: [UnsafeMutablePointer<cmark_node>] = []
        var child = cmark_node_first_child(node)
        while let current = child { result.append(current); child = cmark_node_next(current) }
        return result
    }
    private func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String { cmark_node_get_literal(node).map(String.init(cString:)) ?? "" }
    private func nodeName(_ node: UnsafeMutablePointer<cmark_node>) -> String { cmark_node_get_type_string(node).map(String.init(cString:)) ?? "" }
    private func collectFootnoteNumbers(_ node: UnsafeMutablePointer<cmark_node>) {
        if cmark_node_get_type(node) == CMARK_NODE_FOOTNOTE_REFERENCE,
           let definition = cmark_node_parent_footnote_def(node) {
            let id = literal(definition)
            if footnoteNumbers[id] == nil { footnoteNumbers[id] = footnoteNumbers.count + 1 }
        }
        for child in children(node) { collectFootnoteNumbers(child) }
    }

    private func renderBlock(_ node: UnsafeMutablePointer<cmark_node>, into output: NSMutableAttributedString, listLevel: Int, quoteLevel: Int) {
        let type = cmark_node_get_type(node)
        let name = nodeName(node)
        if name == "table" { renderTable(node, into: output); return }
        if type == CMARK_NODE_LIST {
            let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
            var number = Int(cmark_node_get_list_start(node))
            for item in children(node) {
                let task = nodeName(item) == "tasklist"
                let kind = task ? "task" : ordered ? "ordered" : "bullet"
                let checked = task && cmark_gfm_extensions_get_tasklist_item_checked(item)
                var firstParagraph = true
                for child in children(item) {
                    if cmark_node_get_type(child) == CMARK_NODE_LIST {
                        renderBlock(child, into: output, listLevel: listLevel + 1, quoteLevel: quoteLevel)
                    } else if cmark_node_get_type(child) == CMARK_NODE_PARAGRAPH {
                        var attrs = MarkdownStyle.attributes(fontSize: fontSize, block: "list", level: listLevel)
                        attrs[.newlineListKind] = kind
                        attrs[.newlineListNumber] = number
                        attrs[.newlineTaskChecked] = checked
                        attrs[.newlineQuoteLevel] = quoteLevel
                        if firstParagraph {
                            var prefixAttrs = attrs
                            prefixAttrs[.newlineGeneratedPrefix] = true
                            output.append(NSAttributedString(string: MarkdownStyle.listPrefix(kind: kind, number: number, checked: checked), attributes: prefixAttrs))
                        }
                        renderInlineChildren(child, into: output, attributes: attrs)
                        output.append(NSAttributedString(string: "\n", attributes: attrs))
                        firstParagraph = false
                    } else { renderBlock(child, into: output, listLevel: listLevel + 1, quoteLevel: quoteLevel) }
                }
                number += 1
            }
            return
        }
        if type == CMARK_NODE_BLOCK_QUOTE {
            for child in children(node) { renderBlock(child, into: output, listLevel: listLevel, quoteLevel: quoteLevel + 1) }
            return
        }
        var block = quoteLevel > 0 ? "quote" : "paragraph"
        if type == CMARK_NODE_HEADING { block = "heading" }
        else if type == CMARK_NODE_CODE_BLOCK { block = "code" }
        else if type == CMARK_NODE_HTML_BLOCK || type == CMARK_NODE_CUSTOM_BLOCK { block = "raw" }
        else if type == CMARK_NODE_THEMATIC_BREAK { block = "rule" }
        else if type == CMARK_NODE_FOOTNOTE_DEFINITION { block = "footnote" }
        var attrs = MarkdownStyle.attributes(fontSize: fontSize, block: block, heading: Int(cmark_node_get_heading_level(node)), level: quoteLevel)
        attrs[.newlineQuoteLevel] = quoteLevel
        if block == "code" {
            attrs[.newlineCodeLanguage] = cmark_node_get_fence_info(node).map(String.init(cString:)) ?? ""
            let code = literal(node)
            output.append(NSAttributedString(string: code.hasSuffix("\n") ? code : code + "\n", attributes: attrs))
        } else if block == "raw" {
            let raw = literal(node)
            output.append(NSAttributedString(string: raw.hasSuffix("\n") ? raw : raw + "\n", attributes: attrs))
        } else if block == "rule" {
            output.append(NSAttributedString(string: "────────────────────\n", attributes: attrs))
        } else if block == "footnote" {
            let definitionStart = output.length
            let id = literal(node)
            attrs[.newlineFootnoteID] = id
            var prefixAttrs = attrs
            prefixAttrs[.newlineGeneratedPrefix] = true
            prefixAttrs[.link] = URL(string: "newline-footnote://reference/" + encodePath(id))
            output.append(NSAttributedString(string: "\(footnoteNumbers[id] ?? 1).\t", attributes: prefixAttrs))
            let paragraphs = children(node)
            for (index, child) in paragraphs.enumerated() {
                if index > 0 { output.append(NSAttributedString(string: "\n", attributes: attrs)) }
                if cmark_node_get_type(child) == CMARK_NODE_PARAGRAPH { renderInlineChildren(child, into: output, attributes: attrs) }
                else {
                    // Keep complex definition content in the editable footnote without losing its block semantics.
                    renderBlock(child, into: output, listLevel: 0, quoteLevel: 0)
                }
            }
            output.append(NSAttributedString(string: "\n", attributes: attrs))
            output.addAttributes([.newlineFootnoteDefinition: true, .newlineFootnoteID: id], range: NSRange(location: definitionStart, length: output.length - definitionStart))
        } else {
            renderInlineChildren(node, into: output, attributes: attrs)
            output.append(NSAttributedString(string: "\n", attributes: attrs))
        }
    }

    private func renderInlineChildren(_ node: UnsafeMutablePointer<cmark_node>, into output: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any]) {
        for child in children(node) { renderInline(child, into: output, attributes: attributes) }
    }
    private func renderInline(_ node: UnsafeMutablePointer<cmark_node>, into output: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any]) {
        var attrs = attributes
        let type = cmark_node_get_type(node)
        switch type {
        case CMARK_NODE_TEXT:
            output.append(NSAttributedString(string: literal(node), attributes: attrs))
        case CMARK_NODE_HTML_INLINE:
            attrs[.newlineRawInline] = true
            output.append(NSAttributedString(string: literal(node), attributes: attrs))
        case CMARK_NODE_SOFTBREAK:
            output.append(NSAttributedString(string: " ", attributes: attrs))
        case CMARK_NODE_LINEBREAK:
            attrs[.newlineHardBreak] = true
            output.append(NSAttributedString(string: "\u{2028}", attributes: attrs))
        case CMARK_NODE_CODE:
            attrs[.newlineInlineCode] = true
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
            output.append(NSAttributedString(string: literal(node), attributes: attrs))
        case CMARK_NODE_EMPH, CMARK_NODE_STRONG:
            attrs[type == CMARK_NODE_STRONG ? .newlineBold : .newlineItalic] = true
            attrs[.font] = MarkdownStyle.font(for: attrs, size: fontSize)
            renderInlineChildren(node, into: output, attributes: attrs)
        case CMARK_NODE_LINK:
            let url = cmark_node_get_url(node).map(String.init(cString:)) ?? ""
            attrs[.link] = URL(string: url) ?? url as Any
            attrs[.newlineLinkTitle] = cmark_node_get_title(node).map(String.init(cString:)) ?? ""
            attrs[.foregroundColor] = NSColor.linkColor
            renderInlineChildren(node, into: output, attributes: attrs)
        case CMARK_NODE_IMAGE:
            let source = cmark_node_get_url(node).map(String.init(cString:)) ?? ""
            let alt = inlinePlainText(node)
            attrs[.newlineImageSource] = source
            attrs[.newlineImageAlt] = alt
            attrs[.newlineImageTitle] = cmark_node_get_title(node).map(String.init(cString:)) ?? ""
            let attachment = NSTextAttachment()
            let url = resolveImage(source)
            let image = url.flatMap { $0.isFileURL ? NSImage(contentsOf: $0) : nil }
            if let image, image.size.width > 0, image.size.height > 0 {
                attachment.image = image
                let scale = min(1, min(620 / image.size.width, 420 / image.size.height))
                attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            } else {
                attachment.image = NSImage(systemSymbolName: "photo", accessibilityDescription: alt.isEmpty ? "Bild nicht verfügbar" : alt)
                attachment.bounds = NSRect(x: 0, y: -3, width: 36, height: 28)
                attrs[.toolTip] = source
            }
            attrs[.attachment] = attachment
            output.append(NSAttributedString(string: "\u{fffc}", attributes: attrs))
        case CMARK_NODE_FOOTNOTE_REFERENCE:
            let id = cmark_node_parent_footnote_def(node).map(literal) ?? literal(node)
            attrs[.newlineFootnoteID] = id
            attrs[.newlineFootnoteReference] = true
            attrs[.newlineFootnoteOccurrence] = UUID().uuidString
            attrs[.link] = URL(string: "newline-footnote://definition/" + encodePath(id))
            attrs[.font] = NSFont.systemFont(ofSize: fontSize * 0.7)
            attrs[.baselineOffset] = fontSize * 0.3
            attrs[.foregroundColor] = NSColor.linkColor
            output.append(NSAttributedString(string: String(footnoteNumbers[id] ?? 1), attributes: attrs))
        default:
            if nodeName(node) == "strikethrough" { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            renderInlineChildren(node, into: output, attributes: attrs)
        }
    }

    private func renderTable(_ node: UnsafeMutablePointer<cmark_node>, into output: NSMutableAttributedString) {
        let columns = max(1, Int(cmark_gfm_extensions_get_table_columns(node)))
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let alignments = cmark_gfm_extensions_get_table_alignments(node)
        for (rowIndex, row) in children(node).enumerated() {
            for (columnIndex, cell) in children(row).enumerated() {
                let cellBlock = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: columnIndex, columnSpan: 1)
                cellBlock.setWidth(0.5, type: .absoluteValueType, for: .border)
                cellBlock.setWidth(8, type: .absoluteValueType, for: .padding)
                cellBlock.setBorderColor(.separatorColor)
                cellBlock.setValue(100 / CGFloat(columns), type: .percentageValueType, for: .width)
                if rowIndex == 0 { cellBlock.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.1) }
                var attrs = MarkdownStyle.attributes(fontSize: fontSize, block: "table")
                let paragraph = (attrs[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                paragraph.textBlocks = [cellBlock]
                paragraph.paragraphSpacing = 3
                let alignment = alignments.map { $0[columnIndex] } ?? 0
                if alignment == 99 { paragraph.alignment = .center }
                else if alignment == 114 { paragraph.alignment = .right }
                attrs[.paragraphStyle] = paragraph
                attrs[.newlineTableRow] = rowIndex
                attrs[.newlineTableColumn] = columnIndex
                attrs[.newlineTableHeader] = rowIndex == 0
                attrs[.newlineTableAlignment] = Int(alignment)
                attrs[.font] = MarkdownStyle.font(for: attrs, size: fontSize)
                renderInlineChildren(cell, into: output, attributes: attrs)
                output.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
    }

    private func inlinePlainText(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        let children = children(node)
        return children.isEmpty ? literal(node) : children.map(inlinePlainText).joined()
    }
    private func resolveImage(_ source: String) -> URL? {
        if let url = URL(string: source), url.scheme != nil { return url }
        guard let baseURL else { return nil }
        let directory = baseURL.hasDirectoryPath ? baseURL : baseURL.deletingLastPathComponent()
        return URL(fileURLWithPath: source.removingPercentEncoding ?? source, relativeTo: directory)
    }
    private func encodePath(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value }

    // MARK: Serialization

    private func serializeBlocks(_ content: NSAttributedString) -> String {
        let string = content.string as NSString
        var paragraphs: [NSAttributedString] = []
        var cursor = 0
        while cursor < string.length {
            let range = string.paragraphRange(for: NSRange(location: cursor, length: 0))
            guard range.length > 0 else { break }
            paragraphs.append(content.attributedSubstring(from: range))
            cursor = NSMaxRange(range)
        }
        var result = ""
        var index = 0
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            let attrs = paragraph.attributes(at: 0, effectiveRange: nil)
            let block = attrs[.newlineBlock] as? String ?? "paragraph"
            let quoteLevel = attrs[.newlineQuoteLevel] as? Int ?? (block == "quote" ? 1 : 0)
            let quotePrefix = String(repeating: "> ", count: quoteLevel)
            if attrs[.newlineFootnoteDefinition] as? Bool == true {
                let id = attrs[.newlineFootnoteID] as? String ?? "note"
                let body = NSMutableAttributedString(string: "")
                while index < paragraphs.count {
                    let p = paragraphs[index]
                    let a = p.attributes(at: 0, effectiveRange: nil)
                    guard a[.newlineFootnoteDefinition] as? Bool == true, a[.newlineFootnoteID] as? String == id else { break }
                    let copy = NSMutableAttributedString(attributedString: p)
                    copy.removeAttribute(.newlineFootnoteDefinition, range: NSRange(location: 0, length: copy.length))
                    if a[.newlineBlock] as? String == "footnote" { copy.addAttribute(.newlineBlock, value: "paragraph", range: NSRange(location: 0, length: copy.length)) }
                    body.append(copy)
                    index += 1
                }
                let serialized = serializeBlocks(body).trimmingCharacters(in: .newlines)
                let lines = serialized.components(separatedBy: "\n")
                result += "[^\(id)]: " + (lines.first ?? "") + "\n"
                for line in lines.dropFirst() { result += line.isEmpty ? "\n" : "    " + line + "\n" }
                continue
            }
            if block == "code" {
                let language = attrs[.newlineCodeLanguage] as? String ?? ""
                var body = ""
                while index < paragraphs.count && paragraphs[index].attribute(.newlineBlock, at: 0, effectiveRange: nil) as? String == "code" {
                    body += paragraphs[index].string
                    index += 1
                }
                let fence = String(repeating: "`", count: max(3, longestBacktickRun(body) + 1))
                result += quoteLines(fence + language + "\n" + body + (body.hasSuffix("\n") ? "" : "\n") + fence + "\n", prefix: quotePrefix)
                continue
            }
            if block == "table" {
                var rows: [Int: [Int: String]] = [:]
                var alignments: [Int: Int] = [:]
                let firstTable = ((attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)?.table
                while index < paragraphs.count && paragraphs[index].attribute(.newlineBlock, at: 0, effectiveRange: nil) as? String == "table" {
                    let cell = paragraphs[index]
                    let a = cell.attributes(at: 0, effectiveRange: nil)
                    let cellTable = ((a[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock)?.table
                    if let firstTable, let cellTable, firstTable !== cellTable { break }
                    let row = a[.newlineTableRow] as? Int ?? 0
                    let column = a[.newlineTableColumn] as? Int ?? 0
                    let text = serializeInline(trimParagraphEnding(cell)).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
                    rows[row, default: [:]][column] = text
                    alignments[column] = a[.newlineTableAlignment] as? Int ?? 0
                    index += 1
                }
                let columns = max(1, (rows.values.flatMap { $0.keys }.max() ?? 0) + 1)
                for (offset, row) in rows.keys.sorted().enumerated() {
                    result += "| " + (0..<columns).map { rows[row]?[$0] ?? "" }.joined(separator: " | ") + " |\n"
                    if offset == 0 {
                        result += "| " + (0..<columns).map { column in alignments[column] == 99 ? ":---:" : alignments[column] == 114 ? "---:" : "---" }.joined(separator: " | ") + " |\n"
                    }
                }
                if index < paragraphs.count { result += "\n" }
                continue
            }
            if block == "raw" { result += paragraph.string; index += 1; continue }
            if block == "rule" { result += quotePrefix + "---\n"; index += 1; continue }
            let body = serializeInline(trimParagraphEnding(paragraph))
            if block == "heading" {
                let level = max(1, min(6, attrs[.newlineHeading] as? Int ?? 1))
                result += quotePrefix + String(repeating: "#", count: level) + " " + body + "\n"
            } else if block == "list" {
                let kind = attrs[.newlineListKind] as? String ?? "bullet"
                let level = attrs[.newlineListLevel] as? Int ?? 0
                let number = attrs[.newlineListNumber] as? Int ?? 1
                let checked = attrs[.newlineTaskChecked] as? Bool == true
                let marker = kind == "ordered" ? "\(number). " : kind == "task" ? (checked ? "- [x] " : "- [ ] ") : "- "
                result += quotePrefix + String(repeating: "    ", count: max(0, level)) + marker + body + "\n"
            } else if block == "footnote" {
                let id = attrs[.newlineFootnoteID] as? String ?? "note"
                result += "[^\(id)]: " + body + "\n"
            } else {
                result += quotePrefix + protectParagraphStart(body) + "\n"
                if index + 1 < paragraphs.count && !body.isEmpty { result += "\n" }
            }
            index += 1
        }
        return result
    }

    private func serializeInline(_ content: NSAttributedString) -> String {
        guard content.length > 0 else { return "" }
        // Cocoa can split a single bold word into several attribute runs for
        // spelling, highlighting or layout. Coalesce by Markdown semantics first;
        // serializing those arbitrary runs as **hel****lo** changes the document.
        let normalized = NSMutableAttributedString(string: content.string)
        let semanticKeys: [NSAttributedString.Key] = [.newlineImageSource, .newlineImageAlt, .newlineImageTitle, .newlineFootnoteID, .newlineFootnoteOccurrence, .newlineLinkTitle]
        let flags: [NSAttributedString.Key] = [.newlineInlineCode, .newlineGeneratedPrefix, .newlineFootnoteReference, .newlineHardBreak, .newlineRawInline]
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
            var semantic: [NSAttributedString.Key: Any] = [:]
            for key in semanticKeys { if let value = attributes[key] { semantic[key] = value } }
            for key in flags { semantic[key] = attributes[key] as? Bool ?? false }
            semantic[.newlineBold] = isBold(attributes)
            semantic[.newlineItalic] = isItalic(attributes)
            semantic[.strikethroughStyle] = attributes[.strikethroughStyle] as? Int ?? 0
            if let link = linkString(attributes[.link]) { semantic[.link] = link }
            normalized.setAttributes(semantic, range: range)
        }
        var result = ""
        var previousFootnoteOccurrence: String?
        normalized.enumerateAttributes(in: NSRange(location: 0, length: normalized.length)) { attrs, range, _ in
            if attrs[.newlineGeneratedPrefix] as? Bool == true { return }
            if let source = attrs[.newlineImageSource] as? String {
                let alt = attrs[.newlineImageAlt] as? String ?? ""
                let title = attrs[.newlineImageTitle] as? String ?? ""
                result += "![" + escape(alt) + "](" + escapeDestination(source) + (title.isEmpty ? "" : " \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\"") + ")"
                return
            }
            if attrs[.newlineFootnoteReference] as? Bool == true, let id = attrs[.newlineFootnoteID] as? String {
                let occurrence = attrs[.newlineFootnoteOccurrence] as? String
                if occurrence == nil || occurrence != previousFootnoteOccurrence { result += "[^\(id)]" }
                previousFootnoteOccurrence = occurrence
                return
            }
            previousFootnoteOccurrence = nil
            if attrs[.newlineHardBreak] as? Bool == true { result += "  \n"; return }
            let literal = (content.string as NSString).substring(with: range)
            if attrs[.newlineRawInline] as? Bool == true { result += literal; return }
            if attrs[.newlineInlineCode] as? Bool == true {
                let fence = String(repeating: "`", count: max(1, longestBacktickRun(literal) + 1))
                let padding = literal.hasPrefix("`") || literal.hasSuffix("`") || (literal.hasPrefix(" ") && literal.hasSuffix(" ") && !literal.trimmingCharacters(in: .whitespaces).isEmpty) ? " " : ""
                var code = fence + padding + literal + padding + fence
                if isItalic(attrs) { code = "*" + code + "*" }
                if isBold(attrs) { code = "**" + code + "**" }
                if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { code = "~~" + code + "~~" }
                if let link = linkString(attrs[.link]), !link.hasPrefix("newline-footnote:") { code = "[" + code + "](" + escapeDestination(link) + ")" }
                result += code
                return
            }
            var text = escape(literal)
            let bold = isBold(attrs)
            let italic = isItalic(attrs)
            let strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
            // Delimiters cannot enclose leading/trailing whitespace in CommonMark.
            if bold || italic || strike {
                let leading = String(text.prefix(while: { $0.isWhitespace }))
                let trailing = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
                let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !core.isEmpty {
                    let marker = (strike ? "~~" : "") + (bold ? "**" : "") + (italic ? "*" : "")
                    let close = (italic ? "*" : "") + (bold ? "**" : "") + (strike ? "~~" : "")
                    text = leading + marker + core + close + trailing
                }
            }
            if let destination = linkString(attrs[.link]), !destination.hasPrefix("newline-footnote:") {
                let title = attrs[.newlineLinkTitle] as? String ?? ""
                text = "[" + text + "](" + escapeDestination(destination) + (title.isEmpty ? "" : " \"" + title.replacingOccurrences(of: "\"", with: "\\\"") + "\"") + ")"
            }
            result += text
        }
        return result
    }

    private func trimParagraphEnding(_ content: NSAttributedString) -> NSAttributedString {
        let string = content.string as NSString
        var length = string.length
        while length > 0 && [10, 13].contains(Int(string.character(at: length - 1))) { length -= 1 }
        return content.attributedSubstring(from: NSRange(location: 0, length: length))
    }
    private func linkString(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }
    private func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            if "\\`*_[]<>~&".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
    private func protectParagraphStart(_ value: String) -> String {
        let ns = value as NSString
        if let expression = try? NSRegularExpression(pattern: "^( {0,3})(#{1,6}(?=\\s)|[-+](?=\\s)|-{3,}$|={3,}$)"),
           let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) {
            return ns.replacingCharacters(in: NSRange(location: match.range(at: 2).location, length: 0), with: "\\")
        }
        if let expression = try? NSRegularExpression(pattern: "^ {0,3}[0-9]{1,9}([.)])(?=\\s)"),
           let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) {
            return ns.replacingCharacters(in: NSRange(location: match.range(at: 1).location, length: 0), with: "\\")
        }
        return value
    }
    private func escapeDestination(_ value: String) -> String {
        if value.contains(where: { $0.isWhitespace }) { return "<" + value.replacingOccurrences(of: ">", with: "%3E") + ">" }
        return value.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
    }
    private func longestBacktickRun(_ value: String) -> Int {
        var longest = 0, current = 0
        for c in value { current = c == "`" ? current + 1 : 0; longest = max(longest, current) }
        return longest
    }
    private func quoteLines(_ value: String, prefix: String) -> String {
        guard !prefix.isEmpty else { return value }
        return value.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { prefix + $0 }.joined(separator: "\n") + "\n"
    }
    private func isBold(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if let explicit = attrs[.newlineBold] as? Bool { return explicit }
        if attrs[.newlineBlock] as? String == "heading" || attrs[.newlineTableHeader] as? Bool == true { return false }
        return (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
    }
    private func isItalic(_ attrs: [NSAttributedString.Key: Any]) -> Bool {
        if let explicit = attrs[.newlineItalic] as? Bool { return explicit }
        return (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
    }
    /// Collision-free semantic records avoid formatting and allocating all attribute
    /// names/values on every keystroke. Font size, colors and layout are deliberately
    /// absent, so presentation changes cannot alter the saved Markdown.
    private struct SemanticStyle: Equatable {
        var block: String
        var heading: Int
        var listLevel: Int
        var listKind: String
        var listNumber: Int
        var flags: UInt16
        var imageSource: String?
        var imageAlt: String
        var imageTitle: String
        var footnoteID: String?
        var codeLanguage: String
        var tableRow: Int
        var tableColumn: Int
        var tableAlignment: Int
        var quoteLevel: Int
        var linkTitle: String
        var strike: Int
        var link: String?
    }
    private struct SemanticRun: Equatable {
        var style: SemanticStyle
        var text: String
    }
    private func semanticSignature(_ text: NSAttributedString, range: NSRange? = nil, string: NSString? = nil) -> [SemanticRun] {
        let range = range ?? NSRange(location: 0, length: text.length)
        let string = string ?? text.string as NSString
        var result: [SemanticRun] = []
        result.reserveCapacity(8)
        var previousReferenceOccurrence: String?
        text.enumerateAttributes(in: range) { attrs, runRange, _ in
            // A list/footnote prefix is generated chrome, never source content.
            if attrs[.newlineGeneratedPrefix] as? Bool == true { previousReferenceOccurrence = nil; return }
            let reference = attrs[.newlineFootnoteReference] as? Bool == true
            let value: String
            if reference {
                let occurrence = attrs[.newlineFootnoteOccurrence] as? String
                value = occurrence != nil && occurrence == previousReferenceOccurrence ? "" : "\u{fffc}"
                previousReferenceOccurrence = occurrence
            } else { value = string.substring(with: runRange); previousReferenceOccurrence = nil }
            guard !value.isEmpty else { return }
            var flags: UInt16 = 0
            if isBold(attrs) { flags |= 1 << 0 }
            if isItalic(attrs) { flags |= 1 << 1 }
            if attrs[.newlineTaskChecked] as? Bool == true { flags |= 1 << 2 }
            if attrs[.newlineInlineCode] as? Bool == true { flags |= 1 << 3 }
            if reference { flags |= 1 << 4 }
            if attrs[.newlineFootnoteDefinition] as? Bool == true { flags |= 1 << 5 }
            if attrs[.newlineTableHeader] as? Bool == true { flags |= 1 << 6 }
            if attrs[.newlineHardBreak] as? Bool == true { flags |= 1 << 7 }
            if attrs[.newlineRawInline] as? Bool == true { flags |= 1 << 8 }
            let style = SemanticStyle(
                block: attrs[.newlineBlock] as? String ?? "paragraph",
                heading: attrs[.newlineHeading] as? Int ?? 0,
                listLevel: attrs[.newlineListLevel] as? Int ?? 0,
                listKind: attrs[.newlineListKind] as? String ?? "bullet",
                listNumber: attrs[.newlineListNumber] as? Int ?? 1,
                flags: flags,
                imageSource: attrs[.newlineImageSource] as? String,
                imageAlt: attrs[.newlineImageAlt] as? String ?? "",
                imageTitle: attrs[.newlineImageTitle] as? String ?? "",
                footnoteID: attrs[.newlineFootnoteID] as? String,
                codeLanguage: attrs[.newlineCodeLanguage] as? String ?? "",
                tableRow: attrs[.newlineTableRow] as? Int ?? 0,
                tableColumn: attrs[.newlineTableColumn] as? Int ?? 0,
                tableAlignment: attrs[.newlineTableAlignment] as? Int ?? 0,
                quoteLevel: attrs[.newlineQuoteLevel] as? Int ?? 0,
                linkTitle: attrs[.newlineLinkTitle] as? String ?? "",
                strike: attrs[.strikethroughStyle] as? Int ?? 0,
                link: linkString(attrs[.link]))
            if result.last?.style == style { result[result.count - 1].text += value }
            else { result.append(SemanticRun(style: style, text: value)) }
        }
        return result
    }
    private func sourceLines(_ string: String) -> [String] {
        guard !string.isEmpty else { return [] }
        var result: [String] = [], current = ""
        for char in string {
            current.append(char)
            if char == "\n" || char == "\r\n" { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
    private func frontMatterLineCount(_ lines: [String]) -> Int {
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---", lines.count > 1 else { return 0 }
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" || line == "..." { return index + 1 }
        }
        return 0
    }
}
