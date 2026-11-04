import AppKit
import NewlineCore

private struct RichTextCheckFailure: Error, CustomStringConvertible { let description: String }

@MainActor
func runRichTextChecks() throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RichTextCheckFailure(description: message) }
        count += 1
    }
    func pasteHTML(_ html: String) throws -> NSAttributedString {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString(html, forType: .html)
        guard let content = RichTextImporter.importContent(from: board, fontSize: 16) else { throw RichTextCheckFailure(description: "HTML paste failed") }
        return content
    }
    let rich = try pasteHTML("<h1>Title</h1><h3>Section</h3><p>A <strong>bold</strong>, <em>italic</em> <a href='https://example.com'>link</a> and <code>x * y</code>.</p><ul><li>One<ul><li>Nested</li></ul></li><li><input type='checkbox' checked>Done</li></ul><ol start='3'><li>Third</li></ol>")
    let markdown = MarkdownCodec().serialize(rich)
    try check(markdown.contains("# Title"), "HTML heading lost: \(markdown)")
    try check(markdown.contains("### Section"), "HTML H3 hierarchy lost")
    try check(markdown.contains("**bold**") && markdown.contains("*italic*"), "HTML emphasis lost")
    try check(markdown.contains("[link](https://example.com)"), "HTML link lost")
    try check(markdown.contains("`x * y`"), "HTML inline code interpreted as emphasis")
    try check(markdown.contains("- One") && markdown.contains("    - Nested"), "HTML nested list lost: \(markdown)")
    try check(markdown.contains("- [x] Done"), "HTML task lost")
    try check(markdown.contains("3. Third"), "HTML ordered-list start lost")

    let table = try pasteHTML("<table><tr><th>Name</th><th style='text-align:right'>Value</th></tr><tr><td><b>One</b></td><td><a href='https://example.com'>Two</a></td></tr><tr><td colspan='2'>Wide</td></tr></table>")
    let tableSource = MarkdownCodec().serialize(table)
    try check(tableSource.contains("| Name | Value |"), "Pasted table header lost")
    try check(tableSource.contains("| **One** | [Two](https://example.com) |"), "Pasted cell formatting lost: \(tableSource)")
    try check(tableSource.contains("| Wide |  |"), "Merged table cell not normalized")
    try check(tableSource.contains("---:"), "Table alignment lost")
    let cellRange = (table.string as NSString).range(of: "One")
    let style = table.attribute(.paragraphStyle, at: cellRange.location, effectiveRange: nil) as? NSParagraphStyle
    try check(style?.textBlocks.first is NSTextTableBlock, "Pasted table is not native editable table")

    let safe = try pasteHTML("<html><head><script>bad()</script><style>body{color:red}</style></head><body><p>Safe<img src='https://example.invalid/image.png' alt='Image'></p><script>never run</script><a href='javascript:alert(1)'>Label</a><p style='color:red;font-size:80px'>Normal</p></body></html>")
    let safeSource = MarkdownCodec().serialize(safe)
    try check(!safeSource.contains("bad()") && !safeSource.contains("never run") && !safeSource.contains("javascript:"), "Active HTML content was retained")
    try check(safeSource.contains("![Image](https://example.invalid/image.png)"), "Remote image reference was lost")
    let normal = (safe.string as NSString).range(of: "Normal")
    let font = safe.attribute(.font, at: normal.location, effectiveRange: nil) as? NSFont
    try check(font?.pointSize == 16, "Foreign HTML font size was retained")

    let rawCode = try pasteHTML("<pre><code class='language-swift'>let x = 1\nprint(x)</code></pre>")
    try check(MarkdownCodec().serialize(rawCode).contains("```swift\nlet x = 1\nprint(x)\n```"), "Fenced pasted code lost whitespace or language")

    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let paragraph = NSMutableParagraphStyle(); paragraph.headerLevel = 2
    let rtfText = NSMutableAttributedString(string: "RTF heading\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 40), .paragraphStyle: paragraph])
    rtfText.append(NSAttributedString(string: "Bold link", attributes: [.font: NSFont.boldSystemFont(ofSize: 40), .link: URL(string: "https://example.com")!, .foregroundColor: NSColor.red]))
    let rtf = try rtfText.data(from: NSRange(location: 0, length: rtfText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    board.setData(rtf, forType: .rtf)
    if let imported = RichTextImporter.importContent(from: board, fontSize: 16) {
        let source = MarkdownCodec().serialize(imported)
        try check(source.contains("RTF heading"), "RTF text lost: \(source)")
        try check(source.contains("[**Bold link**](https://example.com)"), "RTF bold link lost: \(source)")
    } else { throw RichTextCheckFailure(description: "RTF import returned nil") }
    board.clearContents()
    board.setData(Data("{\\rtf1\\ansi\\pard\\outlinelevel1 Explicit heading\\par\\pard Normal text\\par}".utf8), forType: .rtf)
    if let imported = RichTextImporter.importContent(from: board, fontSize: 16) {
        try check(MarkdownCodec().serialize(imported).contains("## Explicit heading"), "Explicit RTF outline heading lost")
    } else { throw RichTextCheckFailure(description: "Outline RTF import failed") }

    // Embedded HTML images remain image bytes until the editor persists them beside the document.
    let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = pixel.representation(using: .png, properties: [:])!
    let image = try pasteHTML("<p>Before<img alt='Tiny' src='data:image/png;base64,\(png.base64EncodedString())'>After</p>")
    let imageLocation = (image.string as NSString).range(of: "\u{fffc}").location
    try check(imageLocation != NSNotFound, "HTML embedded image missing")
    try check(image.attribute(.newlineEmbeddedImageData, at: imageLocation, effectiveRange: nil) as? Data == png, "HTML image bytes lost")
    try check(image.attribute(.attachment, at: imageLocation, effectiveRange: nil) is NSTextAttachment, "HTML image is no longer an attachment")

    board.clearContents()
    let attachment = NSTextAttachment()
    attachment.image = NSImage(data: png)
    attachment.fileWrapper = FileWrapper(regularFileWithContents: png)
    attachment.fileWrapper?.preferredFilename = "Test.png"
    let withImage = NSMutableAttributedString(string: "Before")
    withImage.append(NSAttributedString(attachment: attachment))
    withImage.append(NSAttributedString(string: "After"))
    let rtfd = try withImage.data(from: NSRange(location: 0, length: withImage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    board.setData(rtfd, forType: .rtfd)
    if let imported = RichTextImporter.importContent(from: board, fontSize: 16) {
        let location = (imported.string as NSString).range(of: "\u{fffc}").location
        try check(location != NSNotFound, "RTFD embedded image missing")
        try check(imported.attribute(.newlineEmbeddedImageData, at: location, effectiveRange: nil) is Data, "RTFD embedded image bytes missing")
        try check(imported.attribute(.newlineEmbeddedImageFilename, at: location, effectiveRange: nil) as? String == "Test.png", "RTFD image filename lost")
    } else { throw RichTextCheckFailure(description: "RTFD import failed") }
    return count
}
