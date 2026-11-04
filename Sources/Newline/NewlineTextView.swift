import AppKit
import UniformTypeIdentifiers
import NewlineCore

final class NewlineTextView: NSTextView {
    weak var session: EditorSession?
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateInsets() }
    func updateInsets() {
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        let contentWidth = min(720, max(200, width - 64))
        textContainerInset = NSSize(width: max(24, (width - contentWidth) / 2), height: 38)
        textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        NativeImageLoader.shared.resize(self)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); session?.restyle()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad,.capsLock,.function])
        if modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) {
            let character = event.characters ?? ""
            if character == "+" || character == "=" { EditorPreferences.shared.changeFont(by: 1); return true }
            if character == "-" { EditorPreferences.shared.changeFont(by: -1); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if enclosingScrollView?.isFindBarVisible == true {
            let item = NSMenuItem(); item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performFindPanelAction(item); window?.makeFirstResponder(self)
        } else { session?.statisticsPinned = false; super.cancelOperation(sender) }
    }
    @objc func toggleBold(_ sender: Any?) { session?.toggleInline(.newlineBold) }
    @objc func toggleItalic(_ sender: Any?) { session?.toggleInline(.newlineItalic) }
    @objc func toggleStrike(_ sender: Any?) { session?.toggleInline(.strikethroughStyle) }
    @objc func toggleInlineCode(_ sender: Any?) { session?.toggleInline(.newlineInlineCode) }
    @objc func setHeading(_ sender: Any?) { let level = (sender as? NSMenuItem)?.tag ?? 0; session?.setBlock(level == 0 ? "paragraph" : "heading", heading: level) }
    @objc func toggleBulletList(_ sender: Any?) { session?.setBlock("list", listKind: "bullet") }
    @objc func toggleOrderedList(_ sender: Any?) { session?.setBlock("list", listKind: "ordered") }
    @objc func toggleTaskList(_ sender: Any?) { session?.setBlock("list", listKind: "task") }
    @objc func toggleQuote(_ sender: Any?) { session?.setBlock("quote") }
    @objc func toggleTask(_ sender: Any?) {
        guard let session, let storage = textStorage, storage.length > 0 else { return }
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard range.location < storage.length, storage.attribute(.newlineListKind, at: range.location, effectiveRange: nil) as? String == "task" else { return }
        session.edit("Aufgabe abhaken") { storage, _ in
            let checked = !(storage.attribute(.newlineTaskChecked, at: range.location, effectiveRange: nil) as? Bool ?? false)
            storage.addAttribute(.newlineTaskChecked, value: checked, range: range)
            if range.length > 0 { storage.replaceCharacters(in: NSRange(location: range.location,length: 1), with: checked ? "☑" : "☐") }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let storage = textStorage, index < storage.length,
           let id = storage.attribute(.newlineFootnoteID, at: index, effectiveRange: nil) as? String {
            if storage.attribute(.newlineFootnoteReference, at: index, effectiveRange: nil) as? Bool == true {
                session?.followFootnote(id); return
            }
            if storage.attribute(.newlineGeneratedPrefix, at: index, effectiveRange: nil) as? Bool == true {
                session?.followFootnote(id, reference: true); return
            }
        }
        if let storage = textStorage, index < storage.length,
           storage.attribute(.newlineListKind, at: index, effectiveRange: nil) as? String == "task",
           storage.attribute(.newlineGeneratedPrefix, at: index, effectiveRange: nil) as? Bool == true {
            setSelectedRange(NSRange(location: index, length: 0))
            toggleTask(nil)
            return
        }
        super.mouseDown(with: event)
    }
    private func selectFootnoteForDeletion(at index: Int) {
        guard let storage = textStorage, index >= 0, index < storage.length,
              storage.attribute(.newlineFootnoteReference, at: index, effectiveRange: nil) as? Bool == true else { return }
        var range = NSRange(location: index, length: 1)
        if storage.attribute(.newlineFootnoteOccurrence, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil {
            setSelectedRange(range)
        }
    }
    override func deleteBackward(_ sender: Any?) {
        if selectedRange().length == 0 { selectFootnoteForDeletion(at: selectedRange().location - 1) }
        super.deleteBackward(sender)
    }
    override func deleteForward(_ sender: Any?) {
        if selectedRange().length == 0 { selectFootnoteForDeletion(at: selectedRange().location) }
        super.deleteForward(sender)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if let input = insertString as? String, input == " ", selectedRange().length == 0, markedRange().length == 0, transformPrefix() { return }
        super.insertText(insertString, replacementRange: replacementRange)
        if let input = insertString as? String, let last = input.last,
           ["*", "_", "~", "`"].contains(last), markedRange().length == 0 {
            transformInlineSuffix()
        }
    }
    private func transformInlineSuffix() {
        guard let session, let storage = textStorage, selectedRange().length == 0 else { return }
        let caret = selectedRange().location
        guard caret > 0, caret <= storage.length else { return }
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let attrs = storage.attributes(at: caret - 1, effectiveRange: nil)
        guard !["code", "raw"].contains(attrs[.newlineBlock] as? String ?? ""), attrs[.newlineInlineCode] as? Bool != true else { return }
        let start = max(paragraph.location, caret - 4096)
        let preceding = (string as NSString).substring(with: NSRange(location: start, length: caret - start))
        // A partially typed code span keeps its contents literal until its closing tick.
        let precedingCharacters = Array(preceding)
        let unescapedTicks = precedingCharacters.enumerated().filter { index, char in
            char == "`" && (index == 0 || precedingCharacters[index - 1] != "\\")
        }.count
        if !preceding.hasSuffix("`"), unescapedTicks % 2 == 1 { return }
        let patterns: [(String, NSAttributedString.Key)] = [
            (#"(?<![\\*])\*\*(?=\S)([^\n]+?)(?<=\S)\*\*$"#, .newlineBold),
            (#"(?<![\\_])__(?=\S)([^\n]+?)(?<=\S)__$"#, .newlineBold),
            (#"(?<![\\~])~~(?=\S)([^\n]+?)(?<=\S)~~$"#, .strikethroughStyle),
            (#"(?<![\\`])`([^`\n]+)`$"#, .newlineInlineCode),
            (#"(?<![\\*])\*(?=\S)([^*\n]+?)(?<=\S)\*$"#, .newlineItalic),
            (#"(?<![\\_\p{L}\p{N}])_(?=\S)([^_\n]+?)(?<=\S)_$"#, .newlineItalic)
        ]
        for (pattern, key) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: preceding, range: NSRange(location: 0, length: preceding.utf16.count)) else { continue }
            let full = NSRange(location: start + match.range.location, length: match.range.length)
            let inner = NSRange(location: start + match.range(at: 1).location, length: match.range(at: 1).length)
            session.edit("Markdown formatieren") { storage, text in
                var continuing = text.typingAttributes
                storage.deleteCharacters(in: NSRange(location: NSMaxRange(inner), length: NSMaxRange(full) - NSMaxRange(inner)))
                storage.deleteCharacters(in: NSRange(location: full.location, length: inner.location - full.location))
                let styled = NSRange(location: full.location, length: inner.length)
                storage.addAttribute(key, value: key == .strikethroughStyle ? 1 : true, range: styled)
                var fonts: [(NSRange, NSFont)] = []
                storage.enumerateAttributes(in: styled) { attrs, range, _ in
                    fonts.append((range, MarkdownStyle.font(for: attrs, size: session.fontSize)))
                }
                for (range, font) in fonts { storage.addAttribute(.font, value: font, range: range) }
                continuing.removeValue(forKey: key)
                if key == .newlineInlineCode { continuing.removeValue(forKey: .backgroundColor) }
                continuing[.font] = MarkdownStyle.font(for: continuing, size: session.fontSize)
                text.setSelectedRange(NSRange(location: NSMaxRange(styled), length: 0))
                text.typingAttributes = continuing
            }
            return
        }
    }
    private func transformPrefix() -> Bool {
        guard let session, let storage = textStorage else { return false }
        let caret = selectedRange().location
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: caret,length: 0))
        guard caret >= paragraph.location else { return false }
        if paragraph.location < storage.length, ["code","table","raw"].contains(storage.attribute(.newlineBlock, at: paragraph.location,effectiveRange: nil) as? String ?? "") { return false }
        let prefix = (string as NSString).substring(with: NSRange(location: paragraph.location,length: caret - paragraph.location))
        if ["•\t[ ]", "•\t[x]", "•\t[X]"].contains(prefix) {
            let checked = prefix.lowercased().hasSuffix("[x]")
            session.edit("Aufgabenliste") { storage, text in
                var attrs = storage.attributes(at: paragraph.location, effectiveRange: nil)
                attrs[.newlineListKind] = "task"; attrs[.newlineTaskChecked] = checked
                attrs[.newlineGeneratedPrefix] = true
                let marker = MarkdownStyle.listPrefix(kind: "task", checked: checked)
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: caret - paragraph.location), with: NSAttributedString(string: marker, attributes: attrs))
                let current = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location, length: 0))
                storage.addAttributes([.newlineListKind: "task", .newlineTaskChecked: checked], range: current)
                text.setSelectedRange(NSRange(location: paragraph.location + marker.utf16.count, length: 0))
                attrs.removeValue(forKey: .newlineGeneratedPrefix); text.typingAttributes = attrs
            }
            return true
        }
        var block: String?, heading = 0, listKind: String?
        if (1...6).contains(prefix.count), prefix.allSatisfy({ $0 == "#" }) { block = "heading"; heading = prefix.count }
        else if ["-","*","+"].contains(prefix) { block = "list"; listKind = "bullet" }
        else if prefix.range(of: #"^\d+[.)]$"#, options: .regularExpression) != nil { block = "list"; listKind = "ordered" }
        else if prefix == ">" { block = "quote" }
        guard let block else { return false }
        session.edit("Markdown formatieren") { storage, text in
            let range = NSRange(location: paragraph.location,length: caret - paragraph.location)
            storage.replaceCharacters(in: range, with: "")
            var attrs = MarkdownStyle.attributes(fontSize: session.fontSize, block: block, heading: heading)
            attrs[.newlineBlockID] = UUID().uuidString
            if let listKind {
                attrs[.newlineListKind] = listKind; attrs[.newlineListLevel] = 0; attrs[.newlineListNumber] = 1
                var prefixAttrs = attrs; prefixAttrs[.newlineGeneratedPrefix] = true
                let p = MarkdownStyle.listPrefix(kind: listKind, number: 1, checked: false)
                storage.insert(NSAttributedString(string: p,attributes: prefixAttrs), at: paragraph.location)
                text.setSelectedRange(NSRange(location: paragraph.location + p.utf16.count,length: 0))
            } else { text.setSelectedRange(NSRange(location: paragraph.location,length: 0)) }
            if paragraph.location < storage.length {
                let newRange = (storage.string as NSString).paragraphRange(for: NSRange(location: paragraph.location,length: 0))
                storage.addAttributes(attrs, range: newRange)
            }
            text.typingAttributes = attrs
        }
        return true
    }
    override func insertNewline(_ sender: Any?) {
        guard let session, let storage = textStorage else { super.insertNewline(sender); return }
        let caret = selectedRange().location
        let range = (string as NSString).paragraphRange(for: NSRange(location: caret,length: 0))
        let attrs = caret < storage.length ? storage.attributes(at: caret,effectiveRange: nil) : typingAttributes
        let block = attrs[.newlineBlock] as? String ?? "paragraph"
        let paragraphText = (string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        if block == "table" { insertTab(sender); return }
        if paragraphText.hasPrefix("```"), block != "code" {
            let language = String(paragraphText.dropFirst(3))
            session.edit("Codeblock") { storage, text in
                var codeAttrs = MarkdownStyle.attributes(fontSize: session.fontSize,block: "code"); codeAttrs[.newlineCodeLanguage] = language
                storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: codeAttrs))
                text.setSelectedRange(NSRange(location: range.location,length: 0)); text.typingAttributes = codeAttrs
            }; return
        }
        if block == "list" {
            let kind = attrs[.newlineListKind] as? String ?? "bullet"
            let number = (attrs[.newlineListNumber] as? Int ?? 0) + 1
            var visible = paragraphText
            if let tab = visible.firstIndex(of: "\t") { visible = String(visible[visible.index(after: tab)...]) }
            if visible.trimmingCharacters(in: CharacterSet(charactersIn: "•☐☑0123456789. \t")).isEmpty { session.setBlock("paragraph"); return }
            session.edit("Listenpunkt") { storage, text in
                var attrs = attrs; attrs[.newlineBlockID] = UUID().uuidString; attrs[.newlineListNumber] = number; attrs[.newlineTaskChecked] = false; attrs.removeValue(forKey: .newlineGeneratedPrefix)
                let insertion = NSMutableAttributedString(string: "\n", attributes: attrs)
                var p = attrs; p[.newlineGeneratedPrefix] = true
                insertion.append(NSAttributedString(string: MarkdownStyle.listPrefix(kind: kind,number: number,checked: false),attributes: p))
                storage.replaceCharacters(in: text.selectedRange(),with: insertion)
                text.setSelectedRange(NSRange(location: caret + insertion.length,length: 0)); text.typingAttributes = attrs
            }; return
        }
        super.insertNewline(sender)
        if block == "heading" || block == "rule" || block == "footnote" {
            typingAttributes = MarkdownStyle.attributes(fontSize: session.fontSize)
        }
    }
    override func insertTab(_ sender: Any?) { if !navigateTable(backward: false) { if !indentList(by: 1) { super.insertTab(sender) } } }
    override func insertBacktab(_ sender: Any?) { if !navigateTable(backward: true) { if !indentList(by: -1) { super.insertBacktab(sender) } } }
    private func indentList(by delta: Int) -> Bool {
        guard let storage = textStorage, storage.length > 0, let session else { return false }
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard range.location < storage.length, storage.attribute(.newlineBlock, at: range.location,effectiveRange: nil) as? String == "list" else { return false }
        let level = max(0, (storage.attribute(.newlineListLevel, at: range.location,effectiveRange: nil) as? Int ?? 0) + delta)
        session.edit("Liste einrücken") { storage, _ in
            storage.addAttribute(.newlineListLevel,value: level,range: range)
            MarkdownStyle.applyParagraph("list",to: storage,range: range,fontSize: session.fontSize,level: level)
        }; return true
    }
    private func navigateTable(backward: Bool) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let pos = min(selectedRange().location,storage.length-1)
        guard let currentTable = table(at: pos) else { return false }
        let range = (string as NSString).paragraphRange(for: NSRange(location: pos,length: 0))
        let next = backward ? max(0,range.location-1) : NSMaxRange(range)
        if next < storage.length, table(at: next) === currentTable {
            let target = (string as NSString).paragraphRange(for: NSRange(location: next,length: 0))
            setSelectedRange(NSRange(location: target.location,length: max(0,target.length-1))); scrollRangeToVisible(target)
        } else if !backward { tableAction("rowAfter") }
        return true
    }
    private func table(at index: Int) -> NSTextTable? {
        guard let storage = textStorage, index >= 0, index < storage.length,
              storage.attribute(.newlineBlock, at: index, effectiveRange: nil) as? String == "table",
              let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle else { return nil }
        return style.textBlocks.compactMap { $0 as? NSTextTableBlock }.first?.table
    }
    @objc func insertLink(_ sender: Any?) {
        guard let session, let window else { return }
        let range = selectedRange()
        let existing = range.location < attributedString().length ? attributedString().attribute(.link,at: range.location,effectiveRange: nil) : nil
        let field = NSTextField(string: (existing as? URL)?.absoluteString ?? existing as? String ?? "https://")
        field.frame = NSRect(x: 0,y: 0,width: 340,height: 24)
        let alert = NSAlert(); alert.messageText = "Link"; alert.informativeText = "Adresse eingeben. Eine leere Adresse entfernt den Link."
        alert.accessoryView = field; alert.addButton(withTitle: "Übernehmen"); alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            session.edit("Link bearbeiten") { storage, text in
                let url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if range.length > 0 {
                    if url.isEmpty { storage.removeAttribute(.link,range: range) } else { storage.addAttribute(.link,value: url,range: range) }
                } else if !url.isEmpty {
                    var attrs = MarkdownStyle.attributes(fontSize: session.fontSize); attrs[.link] = url
                    storage.insert(NSAttributedString(string: url,attributes: attrs),at: range.location)
                    text.setSelectedRange(NSRange(location: range.location + url.utf16.count,length: 0))
                }
            }
        }
        window.sheetParent?.makeFirstResponder(field)
    }
    @objc func insertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { self?.session?.insertImage(data: try Data(contentsOf: url),name: url.lastPathComponent) } catch { NSApp.presentError(error) }
        }
    }
    @objc func insertTable(_ sender: Any?) {
        guard let window else { return }
        let rows = NSTextField(string: "3"), columns = NSTextField(string: "2")
        let stack = NSStackView(views: [NSTextField(labelWithString: "Zeilen (mit Kopfzeile)"),rows,NSTextField(labelWithString: "Spalten"),columns]); stack.orientation = .vertical; stack.alignment = .leading; stack.frame = NSRect(x: 0,y: 0,width: 260,height: 110)
        let alert = NSAlert(); alert.messageText = "Tabelle einfügen"; alert.accessoryView = stack; alert.addButton(withTitle: "Einfügen"); alert.addButton(withTitle: "Abbrechen")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let r = min(100,max(2,rows.integerValue)), c = min(20,max(1,columns.integerValue))
            let header = "| " + (1...c).map { "Spalte \($0)" }.joined(separator: " | ") + " |\n"
            let separator = "| " + Array(repeating: "---",count: c).joined(separator: " | ") + " |\n"
            let row = "| " + Array(repeating: " ",count: c).joined(separator: " | ") + " |\n"
            self?.session?.insertMarkdown("\n" + header + separator + String(repeating: row,count: r-1) + "\n",name: "Tabelle einfügen")
        }
    }
    @objc func insertFootnote(_ sender: Any?) {
        guard let session else { return }
        let id = "note-" + UUID().uuidString.prefix(6)
        session.edit("Fußnote einfügen") { storage, text in
            let range = text.selectedRange()
            var ref = MarkdownStyle.attributes(fontSize: session.fontSize)
            ref[.newlineFootnoteOccurrence] = UUID().uuidString; ref[.newlineFootnoteID] = String(id); ref[.newlineFootnoteReference] = true; ref[.superscript] = 1; ref[.link] = "newline-footnote://definition/\(id)"
            storage.replaceCharacters(in: range,with: NSAttributedString(string: "⁎",attributes: ref))
            let noteStart = storage.length + 2
            storage.append(NSAttributedString(string: "\n\n",attributes: MarkdownStyle.attributes(fontSize: session.fontSize)))
            var note = MarkdownStyle.attributes(fontSize: session.fontSize,block: "footnote"); note[.newlineFootnoteID] = String(id); note[.newlineFootnoteDefinition] = true; note[.newlineBlockID] = UUID().uuidString
            var prefix = note; prefix[.newlineGeneratedPrefix] = true; prefix[.link] = "newline-footnote://reference/\(id)"
            storage.append(NSAttributedString(string: "⁎  ",attributes: prefix))
            storage.append(NSAttributedString(string: "Fußnote\n",attributes: note))
            text.setSelectedRange(NSRange(location: noteStart + 3,length: 7)); text.scrollRangeToVisible(text.selectedRange())
        }
    }
    @objc func insertCodeBlock(_ sender: Any?) { session?.insertMarkdown("\n```\nCode\n```\n",name: "Codeblock einfügen") }
    @objc func insertRule(_ sender: Any?) { session?.insertMarkdown("\n---\n",name: "Trennlinie einfügen") }
    override func clicked(onLink link: Any, at charIndex: Int) {
        let value = (link as? URL)?.absoluteString ?? link as? String ?? ""
        if let url = URL(string: value), url.scheme == "newline-footnote" {
            session?.followFootnote(String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst()), reference: url.host == "reference")
            return
        }
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true, let url = URL(string: value,relativeTo: session?.document?.fileURL?.deletingLastPathComponent()) { NSWorkspace.shared.open(url.absoluteURL) }
    }
    override func paste(_ sender: Any?) {
        pasteContent(from: .general)
    }
    func pasteContent(from board: NSPasteboard) {
        let selected = selectedRange().location
        let attrs = selected < (textStorage?.length ?? 0) ? textStorage!.attributes(at: selected, effectiveRange: nil) : typingAttributes
        // Code receives the literal clipboard text before any rich-text or image path.
        if attrs[.newlineBlock] as? String == "code" || attrs[.newlineInlineCode] as? Bool == true {
            let literal = board.string(forType: .string) ?? RichTextImporter.importContent(from: board, fontSize: session?.fontSize ?? 16)?.string
            if let literal {
                session?.insert(NSAttributedString(string: literal, attributes: attrs))
                typingAttributes = attrs
            }
            return
        }
        if let urls = board.readObjects(forClasses: [NSURL.self],options: [.urlReadingFileURLsOnly:true]) as? [URL], let url = urls.first, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            do { session?.insertImage(data: try Data(contentsOf: url),name: url.lastPathComponent) } catch { NSApp.presentError(error) }; return
        }
        if let data = board.data(forType: .png) { session?.insertImage(data: data,name: "Bild.png"); return }
        if let data = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png,properties: [:]) { session?.insertImage(data: png,name: "Bild.png"); return }
        if let rich = RichTextImporter.importContent(from: board, fontSize: session?.fontSize ?? 16) { session?.insertRichContent(rich); return }
        if let source = board.string(forType: .string) {
            let attrs = typingAttributes
            if attrs[.newlineBlock] as? String == "code" || attrs[.newlineInlineCode] as? Bool == true { session?.insert(NSAttributedString(string: source,attributes: attrs)) }
            else { session?.insertMarkdown(source) }
        }
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if let source = NSPasteboard.general.string(forType: .string) { session?.insert(NSAttributedString(string: source,attributes: typingAttributes)) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],options: [.urlReadingFileURLsOnly:true]) as? [URL], let url = urls.first, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            do { session?.insertImage(data: try Data(contentsOf: url),name: url.lastPathComponent); return true } catch { NSApp.presentError(error); return false }
        }
        return super.performDragOperation(sender)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let storage = textStorage, storage.length > 0 {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow,from: nil))
            if storage.attribute(.newlineBlock,at: min(index,storage.length-1),effectiveRange: nil) as? String == "table" {
                setSelectedRange(NSRange(location: index,length: 0)); menu.addItem(.separator())
                for (title,action) in [("Zeile darüber","rowBefore"),("Zeile darunter","rowAfter"),("Spalte davor","columnBefore"),("Spalte danach","columnAfter"),("Zeile löschen","deleteRow"),("Spalte löschen","deleteColumn")] {
                    let item = NSMenuItem(title: title,action: #selector(tableMenuAction(_:)),keyEquivalent: ""); item.representedObject = action; item.target = self; menu.addItem(item)
                }
            }
        }
        // General rich-text panels can produce formats Markdown cannot represent.
        for item in menu.items where ["orderFrontFontPanel:","orderFrontTablePanel:","changeColor:"].contains(item.action.map(NSStringFromSelector) ?? "") { menu.removeItem(item) }
        return menu
    }
    @objc private func tableMenuAction(_ sender: NSMenuItem) { tableAction(sender.representedObject as? String ?? "") }
    private func tableAction(_ action: String) {
        guard let storage = textStorage, storage.length > 0, let session else { return }
        let selected = min(selectedRange().location,storage.length-1)
        let attrs = storage.attributes(at: selected,effectiveRange: nil)
        guard let selectedTable = table(at: selected) else { return }
        let currentRow = attrs[.newlineTableRow] as? Int ?? 0, currentColumn = attrs[.newlineTableColumn] as? Int ?? 0
        var start = (string as NSString).paragraphRange(for: NSRange(location: selected,length: 0)).location
        while start > 0, table(at: start-1) === selectedTable { start = (string as NSString).paragraphRange(for: NSRange(location: start-1,length: 0)).location }
        var end = start; var cells: [[String]] = []
        var alignmentByColumn: [Int: Int] = [:]
        while end < storage.length, table(at: end) === selectedTable {
            let r = (string as NSString).paragraphRange(for: NSRange(location: end,length: 0))
            let a = storage.attributes(at: end,effectiveRange: nil), row = a[.newlineTableRow] as? Int ?? 0, col = a[.newlineTableColumn] as? Int ?? 0
            while cells.count <= row { cells.append([]) }; while cells[row].count <= col { cells[row].append("") }
            let value = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: r))
            value.addAttribute(.newlineBlock,value: "paragraph",range: NSRange(location: 0,length: value.length))
            value.removeAttribute(.newlineBlockID,range: NSRange(location: 0,length: value.length))
            cells[row][col] = MarkdownCodec().serialize(value).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "|",with: "\\|")
            alignmentByColumn[col] = a[.newlineTableAlignment] as? Int ?? 0
            end = NSMaxRange(r)
        }
        guard !cells.isEmpty else { return }
        let columns = cells.map(\.count).max() ?? 1
        var alignments = (0..<columns).map { alignmentByColumn[$0] ?? 0 }
        for r in cells.indices { while cells[r].count < columns { cells[r].append("") } }
        switch action {
        case "rowBefore": cells.insert(Array(repeating: "",count: columns),at: max(1,min(currentRow,cells.count)))
        case "rowAfter": cells.insert(Array(repeating: "",count: columns),at: min(currentRow+1,cells.count))
        case "columnBefore", "columnAfter":
            let column = min(currentColumn + (action == "columnAfter" ? 1 : 0), columns)
            for r in cells.indices { cells[r].insert("",at: column) }
            alignments.insert(0, at: column)
        case "deleteRow": if cells.count > 2 { cells.remove(at: min(currentRow,cells.count-1)) }
        case "deleteColumn": if columns > 1 {
            let column = min(currentColumn, columns-1)
            for r in cells.indices { cells[r].remove(at: column) }
            alignments.remove(at: column)
        }
        default: return
        }
        var markdown = ""
        for (r,row) in cells.enumerated() {
            markdown += "| " + row.joined(separator: " | ") + " |\n"
            if r == 0 { markdown += "| " + alignments.map { $0 == 99 ? ":---:" : $0 == 114 ? "---:" : $0 == 108 ? ":---" : "---" }.joined(separator: " | ") + " |\n" }
        }
        let rendered = NSMutableAttributedString(attributedString: MarkdownCodec().render(markdown,fontSize: session.fontSize))
        // Preserve the owning codec's block identity and original inter-block spacing.
        if let id = attrs[.newlineBlockID], rendered.length > 0 {
            rendered.addAttribute(.newlineBlockID, value: id, range: NSRange(location: 0, length: rendered.length))
        }
        session.edit("Tabelle bearbeiten") { storage,text in
            storage.replaceCharacters(in: NSRange(location: start,length: end-start),with: rendered)
            text.setSelectedRange(NSRange(location: start,length: 0))
        }
    }
}
