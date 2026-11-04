import AppKit
import Foundation
import NewlineCore

private struct MarkdownCheckFailure: Error, CustomStringConvertible {
    let description: String
}

/// Executable checks use Foundation/AppKit because standalone Command Line Tools
/// do not ship the XCTest framework. The packaged app uses the same core library.
@MainActor
func runMarkdownChecks() throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw MarkdownCheckFailure(description: message) }
        count += 1
    }
    let cases = [
        "", "Hello", "Hello\n", "\n\nHello\n\n", "# Title\n\nA **bold** and _italic_ [link](https://example.com).\n",
        "---\ntitle: Note\n---\n\n# Actual title\n\nText\n",
        "> Quoted **text**\n>\n> - List\n>   - Nested\n",
        "- [x] Done\n- [ ] Open\n\n1. First\n2. Second\n",
        "| Name | Value |\n| :--- | ---: |\n| *One* | `a|b` |\n",
        "Before[^label].\n\n[^label]: Footnote **body**.\n\n[^unused]: Never delete me.\n",
        "[visible][link]\n\n[link]: https://example.com \"A title\"\n",
        "<!-- comment -->\n\n<div>Keep original HTML</div>\n",
        "A  \nhard break and\na soft break.\n\n```swift\nlet x = `backtick`\n```\n",
        "![photo](<images/hello world.png> \"Description\")\n",
        "# Überschrift 😀\r\n\r\nCafé und e\u{301} zusammen.\r\n"
    ]
    for source in cases {
        let codec = MarkdownCodec()
        let text = codec.render(source)
        try check(codec.serialize(text) == source, "Exact unedited round trip failed: \(source.debugDescription)")
        let zoomed = NSMutableAttributedString(attributedString: text)
        codec.restyle(zoomed, fontSize: 25)
        try check(codec.serialize(zoomed) == source, "Zoom changed Markdown: \(source.debugDescription)")
    }

    let codec = MarkdownCodec()
    let source = "# Unchanged Heading\n\nA **bold** paragraph.\n\n[^unused]: Keep this exact definition.\n\n<!-- Keep comment -->\n"
    let edited = NSMutableAttributedString(attributedString: codec.render(source))
    let position = (edited.string as NSString).range(of: "paragraph").location
    edited.replaceCharacters(in: NSRange(location: position, length: 9), with: "sentence")
    let serialized = codec.serialize(edited)
    try check(serialized.hasPrefix("# Unchanged Heading\n\n"), "Unchanged heading spelling changed after another block edit")
    try check(serialized.contains("A **bold** sentence."), "Bold semantic edit lost formatting: \(serialized)")
    try check(serialized.contains("[^unused]: Keep this exact definition."), "Unused footnote was discarded after editing another block")
    try check(serialized.contains("<!-- Keep comment -->"), "HTML comment was discarded after editing another block")

    let tableCodec = MarkdownCodec()
    let table = NSMutableAttributedString(attributedString: tableCodec.render("| First | Second |\n| --- | ---: |\n| one | two |\n"))
    let one = (table.string as NSString).range(of: "one")
    try check(one.location != NSNotFound, "Table text was not rendered")
    let paragraph = table.attribute(.paragraphStyle, at: one.location, effectiveRange: nil) as? NSParagraphStyle
    try check(paragraph?.textBlocks.first is NSTextTableBlock, "Table did not use native text table blocks")
    table.replaceCharacters(in: one, with: "three")
    let tableSource = tableCodec.serialize(table)
    try check(tableSource.contains("| three | two |"), "Edited table cell did not serialize: \(tableSource)")
    try check(!tableSource.contains("**First**"), "Header's display bold leaked into Markdown")
    try check(tableSource.contains("---:"), "Table alignment was lost")

    let noteCodec = MarkdownCodec()
    let notes = NSMutableAttributedString(attributedString: noteCodec.render("One[^a], another[^a], last[^b].\n\n[^a]: Alpha.\n\n[^b]: Beta.\n"))
    var refs: [String] = []
    notes.enumerateAttributes(in: NSRange(location: 0, length: notes.length)) { attrs, _, _ in
        if attrs[.newlineFootnoteReference] as? Bool == true, let id = attrs[.newlineFootnoteID] as? String { refs.append(id) }
    }
    try check(refs == ["a", "a", "b"], "Footnote reference labels changed: \(refs)")
    let alpha = (notes.string as NSString).range(of: "Alpha")
    try check(alpha.location != NSNotFound, "Footnote definition wasn't rendered")
    notes.replaceCharacters(in: alpha, with: "Changed")
    let noteSource = noteCodec.serialize(notes)
    try check(noteSource.contains("[^a]: Changed."), "Edited footnote definition was not retained: \(noteSource)")
    try check(noteSource.contains("One[^a], another[^a], last[^b]."), "Untouched footnote references changed")

    let complexCodec = MarkdownCodec()
    let complex = NSMutableAttributedString(attributedString: complexCodec.render("Text[^note].\n\n[^note]: First paragraph.\n\n    Second **paragraph**.\n\n    ```swift\n    let value = 42\n    ```\n"))
    complex.replaceCharacters(in: (complex.string as NSString).range(of: "First"), with: "Changed")
    let complexSource = complexCodec.serialize(complex)
    try check(complexSource.contains("[^note]: Changed paragraph."), "Complex footnote first paragraph changed incorrectly")
    try check(complexSource.contains("    Second **paragraph**."), "Complex footnote continuation lost indentation: \(complexSource)")
    try check(complexSource.contains("    ```swift\n    let value = 42"), "Complex footnote code lost structure: \(complexSource)")

    let numberedCodec = MarkdownCodec()
    let numberedSource = "First[^a], second[^b], repeat[^a][^a].\n\n[^a]: Alpha.\n\n[^b]: Beta.\n"
    let numbered = NSMutableAttributedString(attributedString: numberedCodec.render(numberedSource))
    try check(numberedCodec.renumberFootnotes(in: numbered).isEmpty, "Initially numbered footnotes should not need display updates")
    var firstReference: NSRange?
    numbered.enumerateAttribute(.newlineFootnoteReference, in: NSRange(location: 0, length: numbered.length)) { value, range, stop in
        if value as? Bool == true { firstReference = range; stop.pointee = true }
    }
    numbered.deleteCharacters(in: firstReference!)
    let changes = numberedCodec.renumberFootnotes(in: numbered)
    try check(changes.count == 5, "Deleting first reference should renumber two definitions + three refs, got \(changes.count)")
    try check(numbered.string.contains("second1, repeat22"), "Reference numbering didn't follow new first-occurrence order: \(numbered.string)")
    let numberedSaved = numberedCodec.serialize(numbered)
    try check(numberedSaved.contains("second[^b], repeat[^a][^a]"), "Renumbering changed stable IDs or lost adjacent references: \(numberedSaved)")
    try check(numberedSaved.contains("[^a]: Alpha."), "Unreferenced definition disappeared")
    let untouchedNumbered = NSMutableAttributedString(attributedString: numberedCodec.render(numberedSource))
    let numberRange = (untouchedNumbered.string as NSString).range(of: "1")
    untouchedNumbered.replaceCharacters(in: numberRange, with: "99")
    let adjustments = numberedCodec.renumberFootnotes(in: untouchedNumbered)
    try check(MarkdownTextReplacement.adjusted(NSRange(location: numberRange.location + 2, length: 0), by: adjustments).location == numberRange.location + 1, "Selection mapping after renumbering failed")
    try check(numberedCodec.serialize(untouchedNumbered) == numberedSource, "Display-only renumbering changed source")

    let unicodeCodec = MarkdownCodec()
    let unicode = NSMutableAttributedString(attributedString: unicodeCodec.render("# 😀\n\nCafé **naïve** e\u{301}.\n"))
    unicode.replaceCharacters(in: (unicode.string as NSString).range(of: "naïve"), with: "schön")
    try check(unicodeCodec.serialize(unicode).contains("Café **schön** e\u{301}."), "UTF-16 edit damaged Unicode or emphasis")

    let escapedCodec = MarkdownCodec()
    let escaped = NSMutableAttributedString(attributedString: escapedCodec.render("Text\n"))
    escaped.replaceCharacters(in: NSRange(location: 0, length: 4), with: "Literal * and [brackets]")
    try check(escapedCodec.serialize(escaped).contains("Literal \\* and \\[brackets\\]"), "Plain inserted text was interpreted as markup during save")
    for literal in ["# heading", "1. numbered", "- list", "> quote", "---", "===", "&copy;", "Text *literal*"] {
        let c = MarkdownCodec()
        let text = NSMutableAttributedString(attributedString: c.render("Original\n"))
        text.replaceCharacters(in: NSRange(location: 0, length: 8), with: literal)
        let saved = c.serialize(text)
        let reopened = MarkdownCodec().render(saved)
        try check(reopened.string == text.string, "Plain text became Markdown on reopen: \(literal) -> \(saved.debugDescription)")
        try check(reopened.attribute(.newlineBlock, at: 0, effectiveRange: nil) as? String == "paragraph", "Plain inserted text changed block type: \(literal)")
    }

    for source in ["**bold *italic* bold** end.\n", "**bold `code` bold** end.\n", "[**bold** plain](https://example.com) end.\n", "~~gone **bold** gone~~ end.\n"] {
        let c = MarkdownCodec()
        let text = NSMutableAttributedString(attributedString: c.render(source))
        text.replaceCharacters(in: (text.string as NSString).range(of: "end"), with: "finish")
        let serialized = c.serialize(text)
        let reparsed = MarkdownCodec().render(serialized)
        try check(reparsed.string == text.string, "Nested inline formatting changed visible text: \(serialized.debugDescription), got \(reparsed.string.debugDescription)")
        for key in [NSAttributedString.Key.newlineBold, .newlineItalic, .newlineInlineCode] {
            var equal = true
            for offset in 0..<text.length where (text.string as NSString).character(at: offset) != 32 {
                if (text.attribute(key, at: offset, effectiveRange: nil) as? Bool ?? false) != (reparsed.attribute(key, at: offset, effectiveRange: nil) as? Bool ?? false) { equal = false; break }
            }
            try check(equal, "Nested inline semantic \(key.rawValue) changed: \(serialized.debugDescription)")
        }
    }
    let splitCodec = MarkdownCodec()
    let split = NSMutableAttributedString(attributedString: splitCodec.render("**helloworld** end.\n"))
    split.addAttribute(.backgroundColor, value: NSColor.red, range: NSRange(location: 0, length: 5))
    split.replaceCharacters(in: (split.string as NSString).range(of: "end"), with: "finish")
    let splitSaved = splitCodec.serialize(split)
    try check(MarkdownCodec().render(splitSaved).string == split.string, "AppKit-only run splitting damaged Markdown: \(splitSaved)")
    let blockStyle = NSMutableAttributedString(attributedString: MarkdownCodec().render("Keep **bold** and *italic*.\n"))
    MarkdownStyle.applyParagraph("heading", to: blockStyle, range: NSRange(location: 0, length: blockStyle.length), fontSize: 16, heading: 2)
    MarkdownStyle.applyParagraph("paragraph", to: blockStyle, range: NSRange(location: 0, length: blockStyle.length), fontSize: 16)
    let boldFont = blockStyle.attribute(.font, at: (blockStyle.string as NSString).range(of: "bold").location, effectiveRange: nil) as! NSFont
    let italicFont = blockStyle.attribute(.font, at: (blockStyle.string as NSString).range(of: "italic").location, effectiveRange: nil) as! NSFont
    try check(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "Changing paragraph kind lost visible bold formatting")
    try check(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask), "Changing paragraph kind lost visible italic formatting")

    let imageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("newline-image-check-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: imageDirectory) }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    bitmap.bitmapData?[0] = 20; bitmap.bitmapData?[1] = 80; bitmap.bitmapData?[2] = 200; bitmap.bitmapData?[3] = 255
    try bitmap.representation(using: .png, properties: [:])!.write(to: imageDirectory.appendingPathComponent("fixture.png"))
    let imageCodec = MarkdownCodec()
    let imageText = imageCodec.render("![Fixture](fixture.png)\n", baseURL: imageDirectory)
    let attachment = imageText.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
    try check(attachment?.image != nil && attachment?.bounds.size == NSSize(width: 20, height: 10), "Relative local PNG wasn't loaded at its intrinsic dimensions")
    try check(imageText.attribute(.newlineImageSource, at: 0, effectiveRange: nil) as? String == "fixture.png", "Image attachment lost its relative source")
    try check(imageCodec.serialize(imageText) == "![Fixture](fixture.png)\n", "Loading image attachment changed source")

    let pastedSource = "First paragraph.\n\nSecond paragraph.\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n| C | D |\n| --- | --- |\n| 3 | 4 |\n"
    let pasted = MarkdownCodec().render(pastedSource)
    let freshDocumentCodec = MarkdownCodec()
    _ = freshDocumentCodec.render("")
    let pastedSaved = freshDocumentCodec.serialize(pasted)
    try check(pastedSaved.contains("First paragraph.\n\nSecond paragraph."), "Pasted independent paragraphs merged during save")
    try check(pastedSaved.contains("| 1 | 2 |\n\n| C | D |"), "Pasted independent tables merged during save")
    try check(MarkdownCodec().render(pastedSaved).string == pasted.string, "Pasted block boundaries changed when reopened")
    let pastedWithoutIDs = NSMutableAttributedString(attributedString: pasted)
    pastedWithoutIDs.removeAttribute(.newlineBlockID, range: NSRange(location: 0, length: pastedWithoutIDs.length))
    let savedWithoutIDs = freshDocumentCodec.serialize(pastedWithoutIDs)
    try check(savedWithoutIDs.contains("| 1 | 2 |\n\n| C | D |"), "Adjacent native tables without source IDs were merged")

    let longSource = String(repeating: "## A section\n\nThis is **formatted** text with a [link](https://example.com).\n\n", count: 1400)
    let start = Date()
    let longCodec = MarkdownCodec()
    let longText = longCodec.render(longSource)
    try check(longCodec.serialize(longText) == longSource, "Large document round trip failed")
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "Markdown 100k-character render + round trip: %.3fs", elapsed))
    let editedLong = NSMutableAttributedString(attributedString: longText)
    editedLong.replaceCharacters(in: NSRange(location: 30, length: 1), with: "X")
    let editStart = Date()
    _ = longCodec.serialize(editedLong)
    print(String(format: "Markdown 100k-character single-edit serialization: %.1fms", Date().timeIntervalSince(editStart) * 1000))
    return count
}
