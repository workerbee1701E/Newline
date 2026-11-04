import AppKit
import Foundation

public extension NSAttributedString.Key {
    static let newlineEmbeddedImageData = Self("Newline.embeddedImageData")
    static let newlineEmbeddedImageFilename = Self("Newline.embeddedImageFilename")
}

/// Imports only Markdown-representable structure. HTML is parsed as inert markup:
/// no WebKit, external entities, scripts, remote stylesheets, or network image loads.
@MainActor
public enum RichTextImporter {
    public static func importContent(from pasteboard: NSPasteboard, fontSize: CGFloat) -> NSAttributedString? {
        if let html = pasteboard.string(forType: .html) ?? pasteboard.data(forType: .html).flatMap({ String(data: $0, encoding: .utf8) }),
           let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
           let root = document.rootElement() {
            let markdown = HTMLMarkdownWriter().write(root).trimmingCharacters(in: .whitespacesAndNewlines)
            let rendered = NSMutableAttributedString(attributedString: withoutSnapshotIDs(MarkdownCodec().render(markdown, fontSize: fontSize)))
            let copy = NSAttributedString(attributedString: rendered)
            copy.enumerateAttribute(.newlineImageSource, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
                guard let source = value as? String, let image = embeddedImage(source), let nativeImage = NSImage(data: image.data) else { return }
                let attachment = imageAttachment(nativeImage)
                rendered.removeAttribute(.newlineImageSource, range: range)
                rendered.addAttributes([.attachment: attachment, .newlineEmbeddedImageData: image.data, .newlineEmbeddedImageFilename: image.filename], range: range)
            }
            return rendered
        }
        if let rtfd = pasteboard.data(forType: .rtfd),
           let imported = try? NSAttributedString(data: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil) {
            return normalizeRTF(imported, fontSize: fontSize)
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let imported = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return normalizeRTF(imported, fontSize: fontSize, headingLevels: rtfHeadingLevels(rtf))
        }
        return nil
    }

    private static func withoutSnapshotIDs(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        if result.length > 0 { result.removeAttribute(.newlineBlockID, range: NSRange(location: 0, length: result.length)) }
        return result
    }

    private static func normalizeRTF(_ original: NSAttributedString, fontSize: CGFloat, headingLevels: [Int: Int] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: original)
        var tableMap: [ObjectIdentifier: NSTextTable] = [:]
        var embedded: [String: (data: Data, filename: String, attachment: NSTextAttachment)] = [:]
        var headingLocations: [Int: Int] = [:]
        var paragraphIndex = 0, paragraphOffset = 0
        let originalString = original.string as NSString
        while paragraphOffset < original.length {
            if let level = headingLevels[paragraphIndex] { headingLocations[paragraphOffset] = level }
            paragraphOffset = NSMaxRange(originalString.paragraphRange(for: NSRange(location: paragraphOffset, length: 0)))
            paragraphIndex += 1
        }
        original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { attributes, range, _ in
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            let paragraphStart = originalString.paragraphRange(for: NSRange(location: range.location, length: 0)).location
            let header = min(6, max(0, headingLocations[paragraphStart] ?? paragraph?.headerLevel ?? 0))
            var clean = MarkdownStyle.attributes(fontSize: fontSize, block: header > 0 ? "heading" : "paragraph", heading: header)
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                clean[.newlineBold] = traits.contains(.boldFontMask) && header == 0
                clean[.newlineItalic] = traits.contains(.italicFontMask)
                if traits.contains(.fixedPitchFontMask) { clean[.newlineInlineCode] = true }
            }
            if let link = attributes[.link] as? URL, isSafeDestination(link.absoluteString) { clean[.link] = link }
            else if let link = attributes[.link] as? String, isSafeDestination(link) { clean[.link] = link }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { clean[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let cell = paragraph?.textBlocks.first as? NSTextTableBlock {
                let key = ObjectIdentifier(cell.table)
                let table = tableMap[key] ?? NSTextTable()
                table.numberOfColumns = cell.table.numberOfColumns
                table.layoutAlgorithm = .automaticLayoutAlgorithm
                table.collapsesBorders = true
                tableMap[key] = table
                let normalized = NSTextTableBlock(table: table, startingRow: cell.startingRow, rowSpan: 1, startingColumn: cell.startingColumn, columnSpan: 1)
                normalized.setWidth(0.5, type: .absoluteValueType, for: .border)
                normalized.setWidth(8, type: .absoluteValueType, for: .padding)
                normalized.setBorderColor(.separatorColor)
                normalized.setValue(100 / CGFloat(max(1, table.numberOfColumns)), type: .percentageValueType, for: .width)
                let style = (clean[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                style.textBlocks = [normalized]
                style.paragraphSpacing = 3
                style.alignment = paragraph?.alignment ?? .left
                clean[.paragraphStyle] = style
                clean[.newlineBlock] = "table"
                clean[.newlineTableRow] = cell.startingRow
                clean[.newlineTableColumn] = cell.startingColumn
                clean[.newlineTableHeader] = cell.startingRow == 0
                clean[.newlineTableAlignment] = style.alignment == .center ? 99 : style.alignment == .right ? 114 : 0
            } else if let lists = paragraph?.textLists, let list = lists.last {
                clean[.newlineBlock] = "list"
                clean[.newlineListLevel] = max(0, lists.count - 1)
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha") || list.markerFormat.rawValue.contains("roman")
                clean[.newlineListKind] = ordered ? "ordered" : "bullet"
                clean[.newlineListNumber] = original.itemNumber(in: list, at: range.location)
                let normalized = MarkdownStyle.attributes(fontSize: fontSize, block: "list", level: lists.count - 1)
                clean[.paragraphStyle] = normalized[.paragraphStyle]
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                let raw = attachment.fileWrapper?.regularFileContents
                let native = attachment.image ?? raw.flatMap(NSImage.init(data:)) ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image
                if let native, let tiff = native.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) {
                    let filename = (attachment.fileWrapper?.preferredFilename as NSString?)?.deletingPathExtension ?? "Bild"
                    let name = filename + ".png"
                    let marker = "newline-embedded://" + UUID().uuidString
                    embedded[marker] = (data, name, imageAttachment(native))
                    clean[.newlineImageSource] = marker
                    clean[.newlineImageAlt] = filename
                } else {
                    clean[.attachment] = attachment
                    clean[.toolTip] = "Eingebettetes Objekt"
                }
            }
            clean[.font] = MarkdownStyle.font(for: clean, size: fontSize)
            if clean[.link] != nil { clean[.foregroundColor] = NSColor.linkColor }
            result.setAttributes(clean, range: range)
        }
        // Cocoa's RTF lists contain a literal tab/marker/tab prefix. Mark it generated
        // so the serializer writes a single Markdown list marker.
        let string = result.string as NSString
        var cursor = 0
        while cursor < result.length {
            let range = string.paragraphRange(for: NSRange(location: cursor, length: 0))
            if result.attribute(.newlineBlock, at: cursor, effectiveRange: nil) as? String == "list" {
                let value = string.substring(with: range)
                if value.hasPrefix("\t"), let second = value.dropFirst().firstIndex(of: "\t") {
                    let prefix = NSRange(value.startIndex...second, in: value)
                    result.addAttribute(.newlineGeneratedPrefix, value: true, range: NSRange(location: cursor, length: prefix.length))
                }
            }
            cursor = NSMaxRange(range)
        }
        // Normalize via the Markdown codec so foreign merged table layouts cannot survive.
        let codec = MarkdownCodec()
        let markdown = codec.serialize(result)
        let normalized = NSMutableAttributedString(attributedString: withoutSnapshotIDs(MarkdownCodec().render(markdown, fontSize: fontSize)))
        let normalizedCopy = NSAttributedString(attributedString: normalized)
        normalizedCopy.enumerateAttribute(.newlineImageSource, in: NSRange(location: 0, length: normalizedCopy.length)) { value, range, _ in
            guard let source = value as? String, let image = embedded[source] else { return }
            normalized.removeAttribute(.newlineImageSource, range: range)
            normalized.addAttributes([.attachment: image.attachment, .newlineEmbeddedImageData: image.data, .newlineEmbeddedImageFilename: image.filename], range: range)
        }
        return normalized
    }

    private static func imageAttachment(_ image: NSImage) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = image
        if image.size.width > 0, image.size.height > 0 {
            let scale = min(1, min(620 / image.size.width, 420 / image.size.height))
            attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        }
        return attachment
    }

    /// Cocoa ignores RTF's explicit outline levels. Read that paragraph metadata
    /// directly, without interpreting font sizes as headings or parsing visible text.
    nonisolated private static func rtfHeadingLevels(_ data: Data) -> [Int: Int] {
        let bytes = Array(data)
        struct State { var ignored = false; var level = 0 }
        var state = State(), stack: [State] = [], result: [Int: Int] = [:]
        var index = 0, paragraph = 0
        let ignored = Set(["fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer", "footnote", "annotation", "listtable", "listoverridetable", "fldinst"])
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 123 { stack.append(state); continue }
            if byte == 125 { if let parent = stack.popLast() { state = parent }; continue }
            guard byte == 92, index < bytes.count else { continue }
            let next = bytes[index]
            if next == 42 { state.ignored = true; index += 1; continue }
            if next == 39 { index = min(bytes.count, index + 3); continue }
            if next == 92 || next == 123 || next == 125 { index += 1; continue }
            if next == 10 || next == 13 {
                if !state.ignored { if state.level > 0 { result[paragraph] = state.level }; paragraph += 1 }
                index += 1
                if next == 13 && index < bytes.count && bytes[index] == 10 { index += 1 }
                continue
            }
            let start = index
            while index < bytes.count && ((65...90).contains(bytes[index]) || (97...122).contains(bytes[index])) { index += 1 }
            guard index > start else { index += 1; continue }
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            let numberStart = index
            if index < bytes.count && bytes[index] == 45 { index += 1 }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            let number = Int(String(decoding: bytes[numberStart..<index], as: UTF8.self))
            if index < bytes.count && bytes[index] == 32 { index += 1 }
            if ignored.contains(word) { state.ignored = true }
            if word == "bin", let length = number { index = min(bytes.count, index + max(0, length)); continue }
            guard !state.ignored else { continue }
            if word == "pard" { state.level = 0 }
            else if word == "outlinelevel", let level = number { state.level = (0...5).contains(level) ? level + 1 : 0 }
            else if word == "par" || word == "line" {
                if state.level > 0 { result[paragraph] = state.level }
                paragraph += 1
            }
        }
        if state.level > 0 { result[paragraph] = state.level }
        return result
    }

    nonisolated fileprivate static func embeddedImage(_ value: String) -> (data: Data, filename: String)? {
        guard value.lowercased().hasPrefix("data:image/"), let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[..<comma].lowercased()
        guard header.hasSuffix(";base64") else { return nil }
        let mime = header.dropFirst(5).split(separator: ";").first.map(String.init) ?? ""
        let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/tiff": "tiff"]
        guard let ext = extensions[mime], let data = Data(base64Encoded: String(value[value.index(after: comma)...]), options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return (data, "Bild." + ext)
    }

    nonisolated fileprivate static func isSafeDestination(_ value: String) -> Bool {
        guard let scheme = URL(string: value)?.scheme?.lowercased() else { return true }
        return ["http", "https", "mailto", "file"].contains(scheme)
    }
}

/// Foundation's HTML tidy parser gives us a tolerant DOM without rendering it.
/// This writer keeps document semantics and intentionally discards visual CSS.
private struct HTMLMarkdownWriter {
    private let ignored: Set<String> = ["head", "script", "style", "iframe", "object", "embed", "noscript", "template", "svg", "canvas"]
    private let blockTags: Set<String> = ["p", "div", "section", "article", "main", "header", "footer", "figure", "figcaption", "address", "dd", "dt"]

    func write(_ node: XMLNode) -> String {
        if node.kind == .text { return escape(collapse(node.stringValue ?? "")) }
        guard let element = node as? XMLElement else { return "" }
        let name = tag(element)
        if ignored.contains(name) || attr(element, "hidden") != nil { return "" }
        if let style = attr(element, "style")?.lowercased(), style.contains("display:none") || style.contains("display: none") { return "" }
        if name.count == 2, name.first == "h", let level = Int(name.suffix(1)), (1...6).contains(level) {
            return "\n\n" + String(repeating: "#", count: level) + " " + children(element).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        switch name {
        case "br": return "  \n"
        case "hr": return "\n\n---\n\n"
        case "ul", "ol": return "\n\n" + list(element, depth: 0) + "\n"
        case "li": return children(element)
        case "pre":
            let codeElement = (element.children ?? []).compactMap { $0 as? XMLElement }.first { tag($0) == "code" }
            let raw = (codeElement ?? element).stringValue ?? ""
            let code = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
            let className = attr(codeElement ?? element, "class") ?? ""
            let language = className.split(separator: " ").first { $0.hasPrefix("language-") }.map { String($0.dropFirst(9)) } ?? ""
            let fence = String(repeating: "`", count: max(3, backtickRun(code) + 1))
            return "\n\n" + fence + language + "\n" + code + "\n" + fence + "\n\n"
        case "code", "kbd", "samp":
            let raw = collapse(element.stringValue ?? "")
            let fence = String(repeating: "`", count: max(1, backtickRun(raw) + 1))
            let padding = raw.hasPrefix("`") || raw.hasSuffix("`") ? " " : ""
            return fence + padding + raw + padding + fence
        case "strong", "b": return wrap(children(element), marker: "**")
        case "em", "i": return wrap(children(element), marker: "*")
        case "s", "strike", "del": return wrap(children(element), marker: "~~")
        case "a":
            let text = children(element)
            guard let href = attr(element, "href"), RichTextImporter.isSafeDestination(href), !href.isEmpty else { return text }
            return "[" + text + "](" + destination(href) + ")"
        case "img":
            guard let src = attr(element, "src"), RichTextImporter.isSafeDestination(src) || RichTextImporter.embeddedImage(src) != nil, !src.isEmpty else { return escape(attr(element, "alt") ?? "") }
            return "![" + escape(attr(element, "alt") ?? "") + "](" + destination(src) + ")"
        case "blockquote":
            return "\n\n" + children(element).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "table": return "\n\n" + table(element) + "\n"
        case "input": return ""
        default:
            var content = children(element)
            // Simple inline CSS exported by Word/Docs often carries semantic emphasis.
            let style = (attr(element, "style") ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            if style.contains("font-weight:bold") || style.contains("font-weight:700") || style.contains("font-weight:600") { content = wrap(content, marker: "**") }
            if style.contains("font-style:italic") { content = wrap(content, marker: "*") }
            if style.contains("text-decoration:line-through") { content = wrap(content, marker: "~~") }
            return blockTags.contains(name) ? "\n\n" + content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" : content
        }
    }

    private func list(_ element: XMLElement, depth: Int) -> String {
        var result = ""
        var number = Int(attr(element, "start") ?? "1") ?? 1
        for item in (element.children ?? []).compactMap({ $0 as? XMLElement }).filter({ tag($0) == "li" }) {
            let nested = (item.children ?? []).compactMap { $0 as? XMLElement }.filter { ["ul", "ol"].contains(tag($0)) }
            let contentNodes = (item.children ?? []).filter { node in !(node is XMLElement && ["ul", "ol"].contains(tag(node))) }
            let checkbox = findElement(item) { tag($0) == "input" && attr($0, "type")?.lowercased() == "checkbox" }
            let checked = checkbox.map { attr($0, "checked") != nil || attr($0, "aria-checked") == "true" } ?? false
            let marker = checkbox != nil ? (checked ? "- [x] " : "- [ ] ") : tag(element) == "ol" ? "\(Int(attr(item, "value") ?? "") ?? number). " : "- "
            let text = contentNodes.map(write).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let indent = String(repeating: "    ", count: depth)
            result += indent + marker + (lines.first ?? "") + "\n"
            for line in lines.dropFirst() { result += indent + String(repeating: " ", count: marker.count) + line + "\n" }
            for child in nested { result += list(child, depth: depth + 1) }
            number += 1
        }
        return result
    }

    private func table(_ element: XMLElement) -> String {
        var rows: [XMLElement] = []
        func collect(_ node: XMLElement) {
            for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
                if tag(child) == "tr" { rows.append(child) }
                else if ["thead", "tbody", "tfoot"].contains(tag(child)) { collect(child) }
            }
        }
        collect(element)
        var cells: [[Int: String]] = Array(repeating: [:], count: rows.count)
        var alignments: [Int: String] = [:]
        for (rowIndex, row) in rows.enumerated() {
            var column = 0
            for cell in (row.children ?? []).compactMap({ $0 as? XMLElement }).filter({ ["th", "td"].contains(tag($0)) }) {
                while cells[rowIndex][column] != nil { column += 1 }
                let columnSpan = max(1, min(100, Int(attr(cell, "colspan") ?? "1") ?? 1))
                let rowSpan = max(1, min(rows.count - rowIndex, Int(attr(cell, "rowspan") ?? "1") ?? 1))
                let text = children(cell).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
                cells[rowIndex][column] = text
                for r in rowIndex..<(rowIndex + rowSpan) {
                    for c in column..<(column + columnSpan) where r != rowIndex || c != column { cells[r][c] = "" }
                }
                let style = (attr(cell, "style") ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                let align = attr(cell, "align")?.lowercased()
                if align == "center" || style.contains("text-align:center") { alignments[column] = ":---:" }
                else if align == "right" || style.contains("text-align:right") { alignments[column] = "---:" }
                column += columnSpan
            }
        }
        let width = min(100, (cells.flatMap { $0.keys }.max() ?? -1) + 1)
        guard width > 0 else { return "" }
        var result = ""
        for (index, row) in cells.enumerated() {
            result += "| " + (0..<width).map { row[$0] ?? "" }.joined(separator: " | ") + " |\n"
            if index == 0 { result += "| " + (0..<width).map { alignments[$0] ?? "---" }.joined(separator: " | ") + " |\n" }
        }
        return result
    }

    private func findElement(_ element: XMLElement, where predicate: (XMLElement) -> Bool) -> XMLElement? {
        if predicate(element) { return element }
        for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
            if let result = findElement(child, where: predicate) { return result }
        }
        return nil
    }
    private func children(_ node: XMLNode) -> String { (node.children ?? []).map(write).joined() }
    private func tag(_ node: XMLNode) -> String { (node.localName ?? node.name ?? "").lowercased() }
    private func attr(_ node: XMLElement, _ name: String) -> String? { node.attribute(forName: name)?.stringValue }
    private func collapse(_ text: String) -> String { text.replacingOccurrences(of: "[\\t\\r\\n ]+", with: " ", options: .regularExpression) }
    private func escape(_ text: String) -> String {
        text.reduce(into: "") { result, char in
            if "\\`*_{}[]<>#+-.!|~".contains(char) { result.append("\\") }
            result.append(char)
        }
    }
    private func destination(_ text: String) -> String { "<" + text.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E").replacingOccurrences(of: "\n", with: "%0A") + ">" }
    private func wrap(_ text: String, marker: String) -> String {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return text }
        let leading = String(text.prefix(while: { $0.isWhitespace }))
        let trailing = String(text.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return leading + marker + core + marker + trailing
    }
    private func backtickRun(_ text: String) -> Int {
        var longest = 0, current = 0
        for character in text { current = character == "`" ? current + 1 : 0; longest = max(current, longest) }
        return longest
    }
}
