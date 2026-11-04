import AppKit
import Foundation

@main
struct CheckRunner {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        do {
            let markdown = try runMarkdownChecks()
            let assets = try runAssetChecks()
            let richText = try runRichTextChecks()
            print("PASS: \(markdown) Markdown checks; \(assets) asset checks; \(richText) rich-text checks")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
