import AppKit
import Combine
import NewlineCore

@MainActor
final class EditorSession: NSObject, ObservableObject, NSTextViewDelegate {
    weak var document: MarkdownDocument?
    weak var textView: NewlineTextView?
    let codec = MarkdownCodec()
    @Published var hovering = false
    @Published var outlineVisible = false
    @Published var statisticsPinned = false
    @Published var headings: [OutlineHeading] = []
    @Published var wordCount = 0
    @Published var characterCount = 0
    @Published var lineCount = 0
    private var updating = false
    private var fontObserver: NSObjectProtocol?
    private var statisticsWork: DispatchWorkItem?
    private var statisticsGeneration = 0
    private(set) var lastSerializationTime: TimeInterval = 0
    private(set) var lastStatisticsTime: TimeInterval = 0
    private(set) var lastFootnoteTime: TimeInterval = 0
    var fontSize: CGFloat { EditorPreferences.shared.fontSize }
    init(document: MarkdownDocument) {
        self.document = document
        super.init()
        fontObserver = NotificationCenter.default.addObserver(forName: .newlineFontChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restyle() }
        }
    }
    deinit { statisticsWork?.cancel(); if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) } }
    func attach(_ text: NewlineTextView) {
        textView = text; text.delegate = self
        reload(document?.source ?? "")
    }
    func reload(_ source: String) {
        guard let text = textView else { return }
        statisticsWork?.cancel(); statisticsGeneration += 1
        updating = true
        let selection = text.selectedRange()
        text.textStorage?.setAttributedString(codec.render(source, baseURL: document?.fileURL?.deletingLastPathComponent(), fontSize: fontSize))
        text.setSelectedRange(NSRange(location: min(selection.location, text.string.utf16.count), length: 0))
        text.typingAttributes = MarkdownStyle.attributes(fontSize: fontSize)
        updating = false
        updateStatistics(source: source)
        NativeImageLoader.shared.refresh(text)
    }
    func restyle() {
        guard let storage = textView?.textStorage else { return }
        updating = true; codec.restyle(storage, fontSize: fontSize); updating = false
        textView?.updateInsets()
        var typing = textView?.typingAttributes ?? [:]
        typing[.font] = MarkdownStyle.font(for: typing, size: fontSize)
        textView?.typingAttributes = typing
    }
    func undoManager(for view: NSTextView) -> UndoManager? { document?.undoManager }
    func textDidChange(_ notification: Notification) {
        guard !updating else { return }
        sync()
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let text = textView else { return }
        var attrs = text.typingAttributes
        attrs.removeValue(forKey: .newlineGeneratedPrefix)
        attrs.removeValue(forKey: .newlineFootnoteReference)
        attrs.removeValue(forKey: .newlineFootnoteOccurrence)
        attrs.removeValue(forKey: .attachment)
        attrs.removeValue(forKey: .newlineImageSource)
        attrs.removeValue(forKey: .newlineImageAlt)
        text.typingAttributes = attrs
    }
    func sync() {
        guard let text = textView, !updating else { return }
        let started = Date.timeIntervalSinceReferenceDate
        if let storage = text.textStorage {
            updating = true
            let selection = text.selectedRange()
            let changes = codec.renumberFootnotes(in: storage)
            if !changes.isEmpty { text.setSelectedRange(MarkdownTextReplacement.adjusted(selection, by: changes)) }
            updating = false
        }
        let numbered = Date.timeIntervalSinceReferenceDate
        let source = codec.serialize(text.attributedString())
        let serialized = Date.timeIntervalSinceReferenceDate
        lastFootnoteTime = numbered - started
        lastSerializationTime = serialized - numbered
        document?.updateSource(source)
        statisticsWork?.cancel(); statisticsGeneration += 1
        if text.string.utf16.count > 20_000 {
            // Source is already current for autosave and Cmd-S. Only secondary
            // UI work waits for a short typing pause in larger documents.
            let generation = statisticsGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.statisticsGeneration == generation else { return }
                self.updateStatistics(source: self.document?.source ?? source)
            }
            statisticsWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
        } else {
            updateStatistics(source: source)
        }
    }
    private func updateStatistics(source: String) {
        guard let text = textView else { return }
        let started = Date.timeIntervalSinceReferenceDate
        defer { lastStatisticsTime = Date.timeIntervalSinceReferenceDate - started }
        let content = text.attributedString()
        let ns = content.string as NSString
        var visible = ""
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attrs, range, _ in
            if attrs[.newlineGeneratedPrefix] as? Bool != true && attrs[.newlineFootnoteReference] as? Bool != true && attrs[.attachment] == nil {
                visible += ns.substring(with: range)
            }
        }
        let characters = visible.filter { !$0.isNewline }.count
        if characterCount != characters { characterCount = characters }
        var count = 0
        visible.enumerateSubstrings(in: visible.startIndex..<visible.endIndex, options: .byWords) { _,_,_,_ in count += 1 }
        if wordCount != count { wordCount = count }
        let lines = source.isEmpty ? 0 : source.split(separator: "\n", omittingEmptySubsequences: false).count - (source.hasSuffix("\n") ? 1 : 0)
        if lineCount != lines { lineCount = lines }
        var found: [OutlineHeading] = []
        var pos = 0
        while pos < content.length {
            let range = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            let attrs = content.attributes(at: pos, effectiveRange: nil)
            if attrs[.newlineBlock] as? String == "heading", let level = attrs[.newlineHeading] as? Int {
                found.append(OutlineHeading(id: pos, title: ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines), level: level, range: range))
            }
            pos = NSMaxRange(range)
        }
        if headings.count != found.count || zip(headings, found).contains(where: { $0.id != $1.id || $0.title != $1.title || $0.level != $1.level || $0.range != $1.range }) { headings = found }
    }
    func navigate(to range: NSRange) {
        guard let text = textView else { return }
        text.window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: min(range.location, text.string.utf16.count), length: 0))
        text.scrollRangeToVisible(range)
    }
    func edit(_ name: String, _ mutation: (NSMutableAttributedString, NewlineTextView) -> Void) {
        guard let text = textView, let storage = text.textStorage else { return }
        let before = NSAttributedString(attributedString: storage)
        let selection = text.selectedRange()
        updating = true
        // Mutations may move the selection or reveal a footnote/table cell. Those
        // operations can ask TextKit to lay out glyphs, which is illegal inside a
        // textStorage beginEditing/endEditing batch. Undo is grouped separately.
        mutation(storage, text)
        updating = false
        document?.undoManager?.registerUndo(withTarget: self) { target in target.restore(before, selection: selection, name: name) }
        document?.undoManager?.setActionName(name)
        text.didChangeText()
    }
    private func restore(_ value: NSAttributedString, selection: NSRange, name: String) {
        guard let text = textView, let storage = text.textStorage else { return }
        let inverse = NSAttributedString(attributedString: storage); let oldSelection = text.selectedRange()
        document?.undoManager?.registerUndo(withTarget: self) { target in target.restore(inverse, selection: oldSelection, name: name) }
        document?.undoManager?.setActionName(name)
        updating = true; storage.setAttributedString(value)
        text.setSelectedRange(NSRange(location: min(selection.location, storage.length), length: min(selection.length, max(0, storage.length - selection.location))))
        updating = false; text.didChangeText()
    }
    func insert(_ content: NSAttributedString, name: String = "Einsetzen") {
        edit(name) { storage, text in
            let range = text.selectedRange()
            storage.replaceCharacters(in: range, with: content)
            text.setSelectedRange(NSRange(location: range.location + content.length, length: 0))
            text.typingAttributes = MarkdownStyle.attributes(fontSize: self.fontSize)
        }
    }
    func insertMarkdown(_ markdown: String, name: String = "Einsetzen") {
        // A separate codec avoids overwriting the original document's source snapshots.
        let parsed = MarkdownCodec().render(markdown, baseURL: document?.fileURL?.deletingLastPathComponent(), fontSize: fontSize)
        insert(parsed, name: name)
        if let textView { NativeImageLoader.shared.refresh(textView) }
    }
    func toggleInline(_ key: NSAttributedString.Key) {
        guard let text = textView else { return }
        let range = text.selectedRange()
        if range.length == 0 {
            var attrs = text.typingAttributes
            let enabled = !(attrs[key] as? Bool ?? false)
            attrs[key] = enabled
            if key == .strikethroughStyle { attrs[key] = enabled ? NSUnderlineStyle.single.rawValue : 0 }
            applyInlineFont(&attrs)
            text.typingAttributes = attrs
            return
        }
        edit("Formatieren") { storage, _ in
            let current = storage.attribute(key, at: range.location, effectiveRange: nil)
            let enabled = key == .strikethroughStyle ? (current as? Int ?? 0) == 0 : !(current as? Bool ?? false)
            storage.addAttribute(key, value: key == .strikethroughStyle ? (enabled ? 1 : 0) : enabled, range: range)
            var changes: [(NSRange,[NSAttributedString.Key:Any])] = []
            storage.enumerateAttributes(in: range) { attrs, range, _ in
                var attrs = attrs; self.applyInlineFont(&attrs); changes.append((range,attrs))
            }
            for (range, attrs) in changes { storage.setAttributes(attrs, range: range) }
        }
    }
    func textView(_ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
                  options: [NSSpellChecker.OptionKey: Any] = [:], results: [NSTextCheckingResult],
                  orthography: NSOrthography, wordCount: Int) -> [NSTextCheckingResult] {
        guard let storage = view.textStorage else { return results }
        return results.filter { result in
            let checked = NSIntersectionRange(result.range, NSRange(location: 0, length: storage.length))
            var containsCode = false
            storage.enumerateAttributes(in: checked) { attrs, _, stop in
                if attrs[.newlineInlineCode] as? Bool == true || attrs[.newlineBlock] as? String == "code" {
                    containsCode = true; stop.pointee = true
                }
            }
            return !containsCode
        }
    }

    private func applyInlineFont(_ attrs: inout [NSAttributedString.Key:Any]) {
        var font = attrs[.font] as? NSFont ?? .systemFont(ofSize: fontSize)
        if attrs[.newlineInlineCode] as? Bool == true { font = MarkdownStyle.font(for: attrs, size: fontSize); attrs.removeValue(forKey: .backgroundColor) }
        else if attrs[.newlineBlock] as? String != "code" { font = .systemFont(ofSize: font.pointSize); attrs.removeValue(forKey: .backgroundColor) }
        if attrs[.newlineBold] as? Bool == true || attrs[.newlineBlock] as? String == "heading" { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if attrs[.newlineItalic] as? Bool == true { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attrs[.font] = font
    }
    func setBlock(_ block: String, heading: Int = 0, listKind: String? = nil) {
        guard let text = textView else { return }
        if let storage = text.textStorage, storage.length > 0 {
            let selection = text.selectedRange()
            let location = min(selection.location, storage.length - 1)
            let checked = NSRange(location: location, length: max(1, min(selection.length, storage.length - location)))
            var includesTable = false
            storage.enumerateAttribute(.newlineBlock, in: checked) { value, _, stop in
                if value as? String == "table" { includesTable = true; stop.pointee = true }
            }
            if includesTable { return }
        }
        if text.string.isEmpty { insert(NSAttributedString(string: "\n", attributes: MarkdownStyle.attributes(fontSize: fontSize)), name: "Absatz") ; text.setSelectedRange(NSRange(location: 0,length: 0)) }
        edit("Absatz formatieren") { storage, text in
            let selected = (storage.string as NSString).paragraphRange(for: text.selectedRange())
            var ranges: [NSRange] = []; var pos = selected.location
            while pos < NSMaxRange(selected) {
                let r = (storage.string as NSString).paragraphRange(for: NSRange(location: pos,length: 0)); ranges.append(r); pos = NSMaxRange(r)
            }
            for range in ranges.reversed() {
                var range = range
                var prefixRange: NSRange = .init(location: range.location,length: 0)
                if range.length > 0, storage.attribute(.newlineGeneratedPrefix, at: range.location, longestEffectiveRange: &prefixRange, in: range) as? Bool == true {
                    storage.deleteCharacters(in: prefixRange); range.length -= prefixRange.length
                }
                for key in [NSAttributedString.Key.newlineHeading, .newlineListLevel, .newlineListKind, .newlineListNumber, .newlineTaskChecked, .newlineGeneratedPrefix] { storage.removeAttribute(key, range: range) }
                MarkdownStyle.applyParagraph(block, to: storage, range: range, fontSize: self.fontSize, heading: heading, level: 0)
                if let kind = listKind {
                    storage.addAttributes([.newlineListKind: kind,.newlineListLevel: 0,.newlineListNumber: 1,.newlineTaskChecked: false], range: range)
                    var attrs = MarkdownStyle.attributes(fontSize: self.fontSize, block: "list")
                    if range.location < storage.length { attrs[.newlineBlockID] = storage.attribute(.newlineBlockID, at: range.location, effectiveRange: nil) }
                    attrs[.newlineListKind] = kind; attrs[.newlineListLevel] = 0; attrs[.newlineListNumber] = 1; attrs[.newlineTaskChecked] = false; attrs[.newlineGeneratedPrefix] = true
                    storage.insert(NSAttributedString(string: MarkdownStyle.listPrefix(kind: kind, number: 1, checked: false), attributes: attrs), at: range.location)
                }
            }
            text.setSelectedRange(NSRange(location: min(selected.location, storage.length),length: 0))
            var attrs = MarkdownStyle.attributes(fontSize: self.fontSize, block: block, heading: heading)
            if let listKind { attrs[.newlineListKind] = listKind; attrs[.newlineListLevel] = 0; attrs[.newlineListNumber] = 1 }
            text.typingAttributes = attrs
        }
    }
    func insertImage(data: Data, name: String) {
        document?.ensureSaved { [weak self] saved in
            guard saved, let self else { return }
            do {
                guard let path = try self.document?.importImage(data: data, preferredName: name) else { return }
                self.insertMarkdown("![\(name.replacingOccurrences(of: "]", with: ""))](\(path))\n", name: "Bild einsetzen")
            } catch { NSApp.presentError(error) }
        }
    }
    func followFootnote(_ id: String, reference: Bool = false) {
        guard let content = textView?.attributedString() else { return }
        var target: NSRange?
        content.enumerateAttributes(in: NSRange(location: 0,length: content.length)) { attrs, range, stop in
            if attrs[.newlineFootnoteID] as? String == id, (attrs[.newlineFootnoteReference] as? Bool == true) == reference { target = range; stop.pointee = true }
        }
        if let target { navigate(to: target) }
    }
}
