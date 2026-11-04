import Foundation
import cmark_gfm

/// Plain Markdown files keep their attachments beside them. Relocations only copy;
/// they never remove source assets, which may also be referenced by another document.
public enum AssetStore {
    public struct Relocation: Sendable {
        public let source: String
        public let copiedFiles: [URL]
    }

    public static func importImage(data: Data, preferredName: String, documentURL: URL) throws -> String {
        let directory = documentURL.deletingLastPathComponent()
            .appendingPathComponent(documentURL.deletingPathExtension().lastPathComponent + ".assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leaf = URL(fileURLWithPath: preferredName).lastPathComponent
        let safeName = leaf.isEmpty || leaf == "." || leaf == ".." ? "Bild.png" : leaf
        let nameURL = URL(fileURLWithPath: safeName)
        let ext = nameURL.pathExtension.isEmpty ? "png" : nameURL.pathExtension
        let stem = nameURL.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent("\(stem).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            suffix += 1
        }
        try data.write(to: destination, options: [.atomic])
        return relativeReference(to: destination, from: documentURL.deletingLastPathComponent())
    }

    public static func prepareRelocation(source: String, from oldDocument: URL, to newDocument: URL) throws -> Relocation {
        let oldDirectory = oldDocument.deletingLastPathComponent().standardizedFileURL
        let newDirectory = newDocument.deletingLastPathComponent().standardizedFileURL
        guard oldDirectory != newDirectory else { return Relocation(source: source, copiedFiles: []) }
        let ns = source as NSString
        var directoryMap: [String: URL] = [:]
        var copiedMap: [URL: URL] = [:]
        var copiedFiles: [URL] = []
        var replacements: [(NSRange, String)] = []

        for range in destinationRanges(in: source) {
            let original = ns.substring(with: range)
            let value = unescapeMarkdown(original)
            guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("/"),
                  value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { continue }
            let suffixStart = value.firstIndex(where: { $0 == "#" || $0 == "?" }) ?? value.endIndex
            let pathPart = String(value[..<suffixStart])
            let suffix = String(value[suffixStart...])
            guard !pathPart.isEmpty else { continue }
            let decoded = pathPart.removingPercentEncoding ?? pathPart
            let oldTarget = oldDirectory.appendingPathComponent(decoded).standardizedFileURL
            var newTarget = oldTarget
            let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let first = components.first == "." ? components.dropFirst().first : components.first
            if let first, first.hasSuffix(".assets"),
               oldTarget.path.hasPrefix(oldDirectory.appendingPathComponent(first).standardizedFileURL.path + "/"),
               FileManager.default.fileExists(atPath: oldTarget.path) {
                if let copied = copiedMap[oldTarget] {
                    newTarget = copied
                } else {
                    let assetDirectory: URL
                    if let existing = directoryMap[first] {
                        assetDirectory = existing
                    } else {
                        var candidate = newDirectory.appendingPathComponent(first, isDirectory: true)
                        var index = 2
                        while FileManager.default.fileExists(atPath: candidate.path) {
                            candidate = newDirectory.appendingPathComponent(String(first.dropLast(7)) + "-\(index).assets", isDirectory: true)
                            index += 1
                        }
                        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                        directoryMap[first] = candidate
                        assetDirectory = candidate
                    }
                    let oldAssetDirectory = oldDirectory.appendingPathComponent(first).standardizedFileURL
                    let tail = String(oldTarget.path.dropFirst(oldAssetDirectory.path.count + 1))
                    let destination = assetDirectory.appendingPathComponent(tail)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: oldTarget, to: destination)
                    copiedMap[oldTarget] = destination
                    copiedFiles.append(destination)
                    newTarget = destination
                }
            }
            replacements.append((range, relativeReference(to: newTarget, from: newDirectory) + suffix))
        }
        let result = NSMutableString(string: source)
        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: replacement)
        }
        return Relocation(source: result as String, copiedFiles: copiedFiles)
    }

    public static func relativeReference(to target: URL, from directory: URL) -> String {
        let base = directory.standardizedFileURL.pathComponents
        let destination = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(base.count, destination.count), base[common] == destination[common] { common += 1 }
        let pieces = Array(repeating: "..", count: base.count - common) + destination.dropFirst(common)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return pieces.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
    }

    /// Destination ranges exclude Markdown punctuation and optional titles. Code is
    /// deliberately masked so a document move cannot rewrite example source code.
    public static func destinationRanges(in source: String) -> [NSRange] {
        let ns = source as NSString
        let units = Array(source.utf16)
        var excluded = Array(repeating: false, count: units.count)
        // Let the Markdown parser distinguish indented code from an indented list
        // item or footnote. Treating every four-space line as code breaks image
        // paths in nested lists when the document is moved.
        var lineRanges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            lineRanges.append(enclosing)
        }
        if let parser = cmark_parser_new(Int32(CMARK_OPT_FOOTNOTES)) {
            source.utf8CString.withUnsafeBufferPointer { cmark_parser_feed(parser, $0.baseAddress, $0.count - 1) }
            if let root = cmark_parser_finish(parser) {
                func maskCode(_ node: UnsafeMutablePointer<cmark_node>) {
                    let type = cmark_node_get_type(node)
                    if type == CMARK_NODE_CODE_BLOCK || type == CMARK_NODE_HTML_BLOCK {
                        let start = max(0, Int(cmark_node_get_start_line(node)) - 1)
                        let end = min(lineRanges.count, Int(cmark_node_get_end_line(node)))
                        if start < end {
                            for line in lineRanges[start..<end] {
                                for index in line.location..<NSMaxRange(line) { excluded[index] = true }
                            }
                        }
                    }
                    var child = cmark_node_first_child(node)
                    while let current = child { maskCode(current); child = cmark_node_next(current) }
                }
                maskCode(root)
                cmark_node_free(root)
            }
            cmark_parser_free(parser)
        }
        if source.hasPrefix("---\n") || source.hasPrefix("---\r\n") {
            let frontmatter = try! NSRegularExpression(pattern: "\\A---\\r?\\n[\\s\\S]*?\\r?\\n(?:---|\\.\\.\\.)(?:\\r?\\n|$)")
            if let match = frontmatter.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) {
                for j in match.range.location..<NSMaxRange(match.range) { excluded[j] = true }
            }
        }
        var i = 0
        while i < units.count {
            if units[i] == 96, !excluded[i] {
                let start = i
                while i < units.count, units[i] == 96 { i += 1 }
                let count = i - start
                var end = i
                while end < units.count {
                    if units[end] == 96 {
                        var runEnd = end
                        while runEnd < units.count, units[runEnd] == 96 { runEnd += 1 }
                        if runEnd - end == count {
                            for j in start..<runEnd { excluded[j] = true }
                            i = runEnd
                            break
                        }
                        end = runEnd
                    } else { end += 1 }
                }
                if end >= units.count { i = start + count }
            } else { i += 1 }
        }

        func escaped(_ index: Int) -> Bool {
            var count = 0, j = index - 1
            while j >= 0, units[j] == 92 { count += 1; j -= 1 }
            return count % 2 != 0
        }
        func readDestination(_ start: Int) -> NSRange? {
            var cursor = start
            while cursor < units.count, units[cursor] == 32 || units[cursor] == 9 { cursor += 1 }
            guard cursor < units.count, !excluded[cursor] else { return nil }
            if units[cursor] == 60 {
                let begin = cursor + 1
                cursor = begin
                while cursor < units.count, units[cursor] != 10 {
                    if units[cursor] == 62, !escaped(cursor) { return NSRange(location: begin, length: cursor - begin) }
                    cursor += 1
                }
                return nil
            }
            let begin = cursor
            var depth = 0
            while cursor < units.count, !excluded[cursor] {
                let unit = units[cursor]
                if !escaped(cursor) {
                    if unit == 40 { depth += 1 }
                    if unit == 41 { if depth == 0 { break }; depth -= 1 }
                    if unit == 32 || unit == 9 || unit == 10 || unit == 13 { break }
                }
                cursor += 1
            }
            return cursor > begin ? NSRange(location: begin, length: cursor - begin) : nil
        }
        func hasOpeningBracket(before end: Int) -> Bool {
            var cursor = end - 1
            var depth = 0
            while cursor >= 0, units[cursor] != 10, !excluded[cursor] {
                if !escaped(cursor) {
                    if units[cursor] == 93 { depth += 1 }
                    if units[cursor] == 91 {
                        if depth == 0 { return true }
                        depth -= 1
                    }
                }
                cursor -= 1
            }
            return false
        }
        var ranges: [NSRange] = []
        i = 0
        while i + 1 < units.count {
            if units[i] == 93, units[i + 1] == 40, !excluded[i], !escaped(i), hasOpeningBracket(before: i),
               let range = readDestination(i + 2) {
                ranges.append(range)
                i = NSMaxRange(range)
            } else { i += 1 }
        }
        let definitions = try! NSRegularExpression(pattern: "(?m)^ {0,3}\\[(?!\\^)[^\\]\\n]+\\]:[ \\t]*")
        definitions.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.range.location < excluded.count, !excluded[match.range.location],
                  let range = readDestination(NSMaxRange(match.range)) else { return }
            ranges.append(range)
        }
        var seen = Set<Int>()
        return ranges.filter { seen.insert($0.location).inserted }.sorted { $0.location < $1.location }
    }

    private static func unescapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "\\\\([\\\\`*{}\\[\\]()#+.!_<> -])", with: "$1", options: .regularExpression)
    }
}
