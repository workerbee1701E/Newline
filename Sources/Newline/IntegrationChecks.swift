import AppKit
import NewlineCore

/// Runs inside the real app binary, without opening windows or touching user files.
@MainActor
func runIntegrationChecks() throws -> Int {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "Newline.IntegrationChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
    let tests: [(String, () throws -> Void)] = [
        ("External in-place and repeated atomic saves refresh the editor", {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineReload-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("Note.md")
            try Data("Original text\n".utf8).write(to: file)
            let f = try EditorCheckFixture(fileURL: file)
            defer { f.document.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            f.text.setSelectedRange(NSRange(location: 2, length: 3))
            for (index, value) in ["External text\n", "# Atomic heading\n", "# Second replacement\n"].enumerated() {
                try Data(value.utf8).write(to: file, options: index == 0 ? [] : .atomic)
                try require(waitUntil { f.document.source == value && f.text.string.contains(index == 0 ? "External" : index == 1 ? "Atomic" : "Second") }, "External save did not reach the document and editor: \(value)")
                try require(!f.document.isDocumentEdited, "Reload made the document dirty")
                try require(f.text.selectedRange() == NSRange(location: 2, length: 3), "Reload lost selection")
            }
            try require(f.session.headings.first?.title == "Second replacement", "Reload did not update the outline")
            f.action { f.type("Local") }
            f.document.undoManager?.undo()
            try require(f.document.source == "# Second replacement\n" && !f.document.isDocumentEdited, "Undo after reload did not return to the new saved baseline")
        }),
        ("External saves preserve unsaved local edits", {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineReloadConflict-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("Note.md")
            try Data("Original\n".utf8).write(to: file)
            let f = try EditorCheckFixture(fileURL: file)
            defer { f.document.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            f.action { f.type("Local ") }
            let local = f.document.source
            try Data("External\n".utf8).write(to: file, options: .atomic)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            try require(f.document.source == local && f.text.string.contains("Local"), "External change discarded local edits")
            try require(f.document.isDocumentEdited, "Conflict incorrectly cleared the dirty state")
            let diskSource = try String(contentsOf: file, encoding: .utf8)
            try require(diskSource == "External\n", "Watcher overwrote the external file")
            f.document.undoManager?.undo()
            try require(waitUntil { f.document.source == "External\n" && f.text.string.contains("External") }, "Undoing local edits did not resume automatic refresh")
        }),
        ("Save As follows the new file and unchanged writes preserve undo", {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineReloadSaveAs-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let oldFile = directory.appendingPathComponent("Old.md")
            let newFile = directory.appendingPathComponent("New.md")
            try Data("Original\n".utf8).write(to: oldFile)
            let f = try EditorCheckFixture(fileURL: oldFile)
            defer { f.document.close() }
            f.action { f.type("Saved ") }
            let savedSource = f.document.source
            var completed = false
            var saveError: Error?
            f.document.save(to: newFile, ofType: "net.daringfireball.markdown", for: .saveAsOperation) { error in
                saveError = error; completed = true
            }
            try require(waitUntil { completed } && saveError == nil, "Save As failed")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            var reloads = 0
            f.document.onSourceReload = { [weak session = f.session] source in
                reloads += 1; session?.reload(source)
            }
            try Data(savedSource.utf8).write(to: newFile, options: .atomic)
            try Data("Old file changed\n".utf8).write(to: oldFile, options: .atomic)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            try require(f.document.source == savedSource && reloads == 0, "Own/unchanged or old-file writes caused a reload")
            try require(f.document.undoManager?.canUndo == true, "Own save discarded undo history")
            try Data("New file changed\n".utf8).write(to: newFile, options: .atomic)
            try require(waitUntil { f.document.source == "New file changed\n" && reloads > 0 }, "Save As did not watch the new path")
            try require(f.document.undoManager?.canUndo == false, "External reload retained undo actions for stale text")
        }),
        ("External reload retains the reading position", {
            let f = try EditorCheckFixture(String(repeating: "A paragraph to scroll through.\n\n", count: 120))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 300))
            f.text.isVerticallyResizable = true
            f.text.maxSize = NSSize(width: 760, height: 100_000)
            scroll.documentView = f.text
            f.text.layoutManager?.ensureLayout(for: f.text.textContainer!)
            f.text.sizeToFit()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            let before = scroll.contentView.bounds.origin
            try require(before.y > 0, "Scroll fixture did not scroll")
            f.session.reload(f.document.source + "Another paragraph.\n")
            try require(scroll.contentView.bounds.origin == before, "Reload jumped away from the reading position")
        }),
        ("File recreation, invalid UTF-8, and closing are safe", {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineReloadRecovery-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("Note.md")
            try Data("Original\n".utf8).write(to: file)
            let f = try EditorCheckFixture(fileURL: file)
            defer { f.document.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try Data([0xFF, 0xFE]).write(to: file)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            try require(f.document.source == "Original\n", "Invalid text replaced the buffer")
            try FileManager.default.removeItem(at: file)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            try require(f.document.source == "Original\n", "Deletion cleared the buffer")
            try Data("Recreated\n".utf8).write(to: file, options: .atomic)
            try require(waitUntil { f.document.source == "Recreated\n" }, "Recreated file was not detected")
            f.document.close()
            try Data("After close\n".utf8).write(to: file, options: .atomic)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            try require(f.document.source == "Recreated\n", "Closed document still refreshed")
        }),
        ("Shortcut help leaves ordinary question marks editable", {
            func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 44)!
            }
            try require(ShortcutHelp.isHelpShortcut(key("?", [.command, .shift])), "Command-Shift-question did not open help")
            try require(!ShortcutHelp.isHelpShortcut(key("?", [])), "Unshifted text was intercepted")
            try require(!ShortcutHelp.isHelpShortcut(key("?", [.shift])), "Typing a question mark was intercepted")
            try require(!ShortcutHelp.isHelpShortcut(key("/", [.shift])), "Different keyboard character was intercepted")
        }),
        ("Duplicate cannot discard relative resource origin", {
            let f = try EditorCheckFixture("![Image](Note.assets/image.png)\n\n[Related](other.md)\n")
            let duplicate = NSMenuItem(title: "Duplizieren", action: #selector(NSDocument.duplicate(_:)), keyEquivalent: "")
            try require(!f.document.validateUserInterfaceItem(duplicate), "AppKit's automatically inserted Duplicate action is enabled despite relative resources")
        }),
        ("Native typing updates the document", {
            let f = try EditorCheckFixture()
            f.action { f.type("Hallo 👩🏽‍💻 Welt") }
            try require(f.document.source.contains("Hallo 👩🏽‍💻 Welt"), "Native text insertion did not update Markdown: \(f.document.source)")
            try require(f.document.isDocumentEdited, "Typing did not mark the document edited")
        }),
        ("Heading input and subsequent paragraph", {
            let f = try EditorCheckFixture()
            f.action { f.type("#"); f.type(" "); f.type("Titel") }
            try require(f.document.source.contains("# Titel"), "Heading shortcut was not serialized: \(f.document.source)")
            f.action { f.text.insertNewline(nil); f.type("Absatz") }
            try require(f.document.source.contains("Absatz") && !f.document.source.contains("# Absatz"), "Return after heading did not restore paragraph style: \(f.document.source)")
            try require(f.session.headings.count == 1, "Outline does not reflect the heading: \(f.session.headings.map(\.title)); source: \(f.document.source)")
        }),
        ("Native typing undo and redo", {
            let f = try EditorCheckFixture("Original\n")
            let original = f.document.source
            f.text.setSelectedRange(NSRange(location: 0, length: 0))
            f.action { f.type("Neu ") }
            let changed = f.document.source
            try require(changed != original, "Native insertion did not change the document")
            f.document.undoManager?.undo()
            try require(f.document.source == original, "Undo did not restore exact original source: \(f.document.source)")
            try require(!f.document.isDocumentEdited, "Undo restored content but left a false document-edited flag")
            f.document.undoManager?.redo()
            try require(f.document.source == changed, "Redo did not restore edited source")
        }),
        ("Semantic formatting undo and redo", {
            let f = try EditorCheckFixture("Hello world\n")
            f.text.setSelectedRange((f.text.string as NSString).range(of: "world"))
            f.action { f.session.toggleInline(.newlineBold) }
            try require(f.document.source.contains("**world**"), "Bold command lost formatting: \(f.document.source)")
            f.document.undoManager?.undo()
            try require(f.document.source == "Hello world\n", "Formatting undo changed original source")
            f.document.undoManager?.redo()
            try require(f.document.source.contains("**world**"), "Formatting redo failed")
        }),
        ("Typed inline Markdown becomes editable formatting", {
            for (syntax, plain, key) in [("**bold**", "bold", NSAttributedString.Key.newlineBold),
                                         ("*italic*", "italic", .newlineItalic),
                                         ("~~strike~~", "strike", .strikethroughStyle),
                                         ("`code`", "code", .newlineInlineCode)] {
                let f = try EditorCheckFixture()
                f.action { for char in syntax { f.type(String(char)) } }
                try require(f.text.string == plain, "Typed syntax did not disappear for \(syntax): \(f.text.string)")
                try require(f.text.textStorage?.attribute(key, at: 0, effectiveRange: nil) != nil, "Typed syntax did not set semantic format for \(syntax)")
                try require(f.document.source.trimmingCharacters(in: .whitespacesAndNewlines) == syntax, "Typed formatting changed Markdown semantics: \(f.document.source)")
            }
        }),
        ("Code span keeps Markdown characters literal", {
            let f = try EditorCheckFixture()
            f.action { for char in "`*literal*`" { f.type(String(char)) } }
            try require(f.text.string == "*literal*", "Markdown was interpreted inside a typed code span: \(f.text.string)")
            try require(f.document.source.trimmingCharacters(in: .whitespacesAndNewlines) == "`*literal*`", "Code span source changed: \(f.document.source)")
        }),
        ("Quote command survives saving and reopening", {
            let f = try EditorCheckFixture("A thought.\n")
            f.text.setSelectedRange(NSRange(location: 0, length: 0))
            f.action { f.text.toggleQuote(nil) }
            try require(f.document.source.hasPrefix("> A thought."), "Quote command lost its Markdown marker: \(f.document.source)")
            let reopened = try EditorCheckFixture(f.document.source)
            try require(reopened.text.textStorage?.attribute(.newlineBlock, at: 0, effectiveRange: nil) as? String == "quote", "Quote was not preserved on reopen")
        }),
        ("List continuation and exit", {
            let f = try EditorCheckFixture("- one\n")
            let one = (f.text.string as NSString).range(of: "one")
            f.text.setSelectedRange(NSRange(location: NSMaxRange(one), length: 0))
            f.action { f.text.insertNewline(nil); f.type("two") }
            try require(f.document.source.contains("- one") && f.document.source.contains("- two"), "List continuation failed: \(f.document.source)")
            f.action { f.text.insertNewline(nil) }
            f.action { f.text.insertNewline(nil); f.type("After") }
            try require(f.document.source.contains("After") && !f.document.source.contains("- After"), "Empty list item did not exit to paragraph: \(f.document.source)")
        }),
        ("Typed task list and checkbox toggle", {
            let f = try EditorCheckFixture()
            f.action { for char in "- [ ] Aufgabe" { f.type(String(char)) } }
            try require(f.document.source.contains("- [ ] Aufgabe"), "Task marker did not become a task list: \(f.document.source)")
            f.text.setSelectedRange(NSRange(location: 0, length: 0))
            f.action { f.text.toggleTask(nil) }
            try require(f.document.source.contains("- [x] Aufgabe"), "Task checkbox did not update Markdown: \(f.document.source)")
            f.document.undoManager?.undo()
            try require(f.document.source.contains("- [ ] Aufgabe"), "Task toggle undo failed")
        }),
        ("Table cells are editable and undoable", {
            let source = "| Name | Value |\n| --- | --- |\n| Alpha | One |\n"
            let f = try EditorCheckFixture(source)
            let cell = (f.text.string as NSString).range(of: "Alpha")
            try require(cell.location != NSNotFound, "Table contents missing from native editor")
            f.text.setSelectedRange(cell)
            f.action { f.type("Beta") }
            try require(f.document.source.contains("Beta") && f.document.source.contains("|"), "Editing cell destroyed table: \(f.document.source)")
            f.document.undoManager?.undo()
            try require(f.document.source == source, "Table undo did not preserve original source")
        }),
        ("Tab navigation preserves table contents", {
            let f = try EditorCheckFixture("| A | B |\n| --- | --- |\n| C | D |\n")
            let before = f.document.source
            f.text.setSelectedRange(NSRange(location: 0, length: 0))
            let previous = f.text.selectedRange().location
            f.text.insertTab(nil)
            try require(f.text.selectedRange().location > previous, "Tab did not navigate to next table cell")
            try require(f.document.source == before, "Tab navigation modified the file")
        }),
        ("Table structure actions and undo preserve contents", {
            let f = try EditorCheckFixture("| A | B |\n| --- | --- |\n| C | D |\n")
            @MainActor func selectC() { f.text.setSelectedRange((f.text.string as NSString).range(of: "C")) }
            @MainActor func dimensions() -> (Int, Int) {
                var rows = Set<Int>(), columns = Set<Int>()
                let content = f.text.attributedString()
                content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attrs, _, _ in
                    if let row = attrs[.newlineTableRow] as? Int { rows.insert(row) }
                    if let column = attrs[.newlineTableColumn] as? Int { columns.insert(column) }
                }
                return (rows.count, columns.count)
            }
            @MainActor func command(_ action: String, selectCell: Bool = true) {
                if selectCell { selectC() }
                let item = NSMenuItem(); item.representedObject = action
                f.action { _ = NSApp.sendAction(Selector(("tableMenuAction:")), to: f.text, from: item) }
            }
            command("rowAfter")
            try require(dimensions().0 == 3, "Add row did not create a third native table row")
            command("columnAfter")
            try require(dimensions().1 == 3, "Add column did not create a third native table column")
            let table = f.text.attributedString()
            table.enumerateAttributes(in: NSRange(location: 0, length: table.length)) { attrs, range, stop in
                if attrs[.newlineTableRow] as? Int == 1, attrs[.newlineTableColumn] as? Int == 1 {
                    f.text.setSelectedRange(NSRange(location: range.location, length: 0)); stop.pointee = true
                }
            }
            command("deleteColumn", selectCell: false)
            try require(dimensions().1 == 2, "Delete column failed")
            command("deleteRow")
            try require(dimensions().0 == 2, "Delete row failed")
            f.document.undoManager?.undo()
            try require(f.text.string.contains("C") && f.text.string.contains("D"), "Undo of table row deletion lost cell contents")
            try require(f.document.source.contains("|"), "Table structure edits no longer serialize as Markdown")
        }),
        ("Adjacent table edits retain both tables and alignment", {
            let first = "| First A | First B |\n| :---: | ---: |\n| Alpha | Beta |\n"
            let second = "| Second A | Second B |\n| --- | --- |\n| Gamma | Delta |\n"
            let source = first + "\n" + second
            let f = try EditorCheckFixture(source)
            f.text.setSelectedRange((f.text.string as NSString).range(of: "Alpha"))
            let command = NSMenuItem(); command.representedObject = "rowAfter"
            f.action { _ = NSApp.sendAction(Selector(("tableMenuAction:")), to: f.text, from: command) }
            try require(["First A", "Alpha", "Second A", "Gamma", "Delta"].allSatisfy(f.text.string.contains), "Table structure edit lost another table's content: \(f.document.source)")
            try require(f.document.source.contains("| :---: | ---: |"), "Structure edit lost column alignment: \(f.document.source)")
            try require(f.document.source.contains(second), "Editing first table changed second table's original source")
            let reopened = try EditorCheckFixture(f.document.source)
            var identities = Set<ObjectIdentifier>()
            reopened.text.attributedString().enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reopened.text.attributedString().length)) { value, _, _ in
                if let cell = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock { identities.insert(ObjectIdentifier(cell.table)) }
            }
            try require(identities.count == 2, "Adjacent tables merged after save/reopen: \(f.document.source)")
            f.document.undoManager?.undo()
            try require(f.document.source == source, "Undo after adjacent-table edit did not restore original source")
        }),
        ("Tab at table boundary does not enter another table", {
            let f = try EditorCheckFixture("| First |\n| --- |\n| Alpha |\n\n| Second |\n| --- |\n| Beta |\n")
            f.text.setSelectedRange((f.text.string as NSString).range(of: "Alpha"))
            f.action { f.text.insertTab(nil) }
            let selected = f.text.selectedRange()
            let second = (f.text.string as NSString).range(of: "Second")
            try require(selected.location < second.location, "Tab crossed into the second table")
            try require(f.text.string.contains("Alpha") && f.text.string.contains("Beta"), "Table-boundary Tab lost cells")
        }),
        ("Block formatting cannot destroy table cells", {
            let source = "| Name | Value |\n| --- | --- |\n| Alpha | Beta |\n"
            let f = try EditorCheckFixture(source)
            f.text.setSelectedRange((f.text.string as NSString).range(of: "Alpha"))
            f.action { f.session.setBlock("heading", heading: 1) }
            try require(f.document.source == source, "Heading command destroyed a table cell")
            f.action { f.session.setBlock("list", listKind: "bullet") }
            try require(f.document.source == source, "List command destroyed a table cell")
        }),
        ("Rich clipboard paste into code remains literal", {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            board.setString("# literal **text**", forType: .string)
            board.setString("<h1>literal <strong>text</strong></h1>", forType: .html)
            for source in ["```\nreplace\n```\n", "A `replace` span.\n"] {
                let f = try EditorCheckFixture(source)
                f.text.setSelectedRange((f.text.string as NSString).range(of: "replace"))
                f.action { f.text.pasteContent(from: board) }
                try require(f.text.string.contains("# literal **text**"), "Rich paste interpreted Markdown inside code: \(f.text.string)")
                try require(f.session.headings.isEmpty, "Rich paste inserted a heading into code")
                let literal = (f.text.string as NSString).range(of: "# literal **text**")
                let attributes = f.text.attributedString().attributes(at: literal.location, effectiveRange: nil)
                try require(attributes[.newlineBlock] as? String == "code" || attributes[.newlineInlineCode] as? Bool == true, "Rich paste removed code semantics")
                f.document.undoManager?.undo()
                try require(f.document.source == source, "One undo did not revert literal code paste")
            }
        }),
        ("Footnote insert edit undo", {
            let f = try EditorCheckFixture("A statement.\n")
            f.text.setSelectedRange(NSRange(location: 11, length: 0))
            f.action { f.text.insertFootnote(nil) }
            try require(f.document.source.contains("[^note-") && f.document.source.contains("]: Fußnote"), "Footnote reference/definition missing: \(f.document.source)")
            f.action { f.type("Erklärung") }
            try require(f.document.source.contains("]: Erklärung"), "Footnote definition is not editable: \(f.document.source)")
            f.document.undoManager?.undo()
            try require(f.document.source.contains("]: Fußnote"), "Footnote content undo failed")
            f.document.undoManager?.undo()
            try require(f.document.source == "A statement.\n", "Footnote insertion undo did not restore original source")
        }),
        ("Footnote references delete atomically and retain definitions", {
            let source = """
Text[^note].

[^note]: Definition.
"""
            let f = try EditorCheckFixture(source)
            var reference = NSRange(location: NSNotFound, length: 0)
            f.text.attributedString().enumerateAttribute(.newlineFootnoteReference, in: NSRange(location: 0, length: f.text.string.utf16.count)) { value, range, _ in
                if value as? Bool == true { reference = range }
            }
            try require(reference.location != NSNotFound, "Reference missing")
            f.text.setSelectedRange(NSRange(location: NSMaxRange(reference), length: 0))
            f.action { f.text.deleteBackward(nil) }
            try require(!f.document.source.contains("Text[^note]") && f.document.source.contains("[^note]: Definition."), "Deleting a reference removed its definition or left a marker")
            f.document.undoManager?.undo()
            try require(f.document.source == source, "Footnote delete undo failed")
        }),
        ("Font zoom leaves file and undo untouched", {
            let f = try EditorCheckFixture("# Heading\n\nBody **bold**.\n")
            let before = f.document.source
            let preferences = EditorPreferences.shared
            let previousSize = preferences.fontSize
            defer { preferences.fontSize = previousSize }
            let beforeFont = f.text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            preferences.changeFont(by: previousSize < 32 ? 1 : -1)
            let afterFont = f.text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            try require(beforeFont?.pointSize != afterFont?.pointSize, "Font zoom did not restyle text")
            try require(f.document.source == before, "Font zoom changed Markdown source")
            try require(f.document.undoManager?.canUndo != true, "Font zoom created a document undo action")
        }),
        ("Replacing a linked label keeps its target", {
            let f = try EditorCheckFixture("Go to [Example](https://example.com/path).\n")
            f.text.setSelectedRange((f.text.string as NSString).range(of: "Example"))
            f.action { f.type("Website") }
            try require(f.document.source.contains("[Website](https://example.com/path)"), "Replacing linked text lost its URL: \(f.document.source)")
        }),
        ("Multi-block insertion is one undo", {
            let f = try EditorCheckFixture("Original\n")
            f.text.setSelectedRange(NSRange(location: f.text.string.utf16.count, length: 0))
            f.action { f.session.insertMarkdown("\n## Pasted\n\n- one\n- two\n") }
            try require(f.document.source.contains("## Pasted") && f.document.source.contains("- two"), "Pasted Markdown lost structure: \(f.document.source)")
            f.document.undoManager?.undo()
            try require(f.document.source == "Original\n", "One undo did not remove the entire insertion")
        }),
        ("Heading followed by multiple paragraphs survives reopening", {
            let f = try EditorCheckFixture()
            f.action { f.type("##"); f.type(" "); f.type("Heading"); f.text.insertNewline(nil); f.type("First"); f.text.insertNewline(nil); f.text.insertNewline(nil); f.type("Second") }
            let source = f.document.source
            let reopened = try EditorCheckFixture(source)
            try require(reopened.session.headings.count == 1, "Reopening introduced or removed headings: \(source)")
            try require(reopened.text.string.contains("First") && reopened.text.string.contains("Second"), "Paragraphs disappeared after serialization")
            try require(reopened.document.source == source, "Reopening normalized the edited source")
        }),
        ("Native document writes and write failure preserve data", {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineDocumentCheck-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = "# Original\r\n\r\nKeep  spacing.\r\n"
            let f = try EditorCheckFixture(source)
            let file = directory.appendingPathComponent("Document.md")
            try f.document.write(to: file, ofType: "net.daringfireball.markdown")
            let written = try Data(contentsOf: file)
            try require(written == Data(source.utf8), "Native file write changed original bytes")
            f.action { f.text.setSelectedRange(NSRange(location: 0, length: 0)); f.type("Edit ") }
            let edited = f.document.source
            let blocked = directory.appendingPathComponent("NotADirectory")
            try Data([1]).write(to: blocked)
            var failed = false
            do { try f.document.write(to: blocked.appendingPathComponent("Fail.md"), ofType: "net.daringfireball.markdown") }
            catch { failed = true }
            try require(failed, "Writing into a file path unexpectedly succeeded")
            try require(f.document.source == edited && f.document.isDocumentEdited, "Write failure lost content or reset the edited flag")
            let afterFailure = try Data(contentsOf: file)
            try require(afterFailure == written, "Failed write changed the original file")
        }),
        ("Save then undo and redo track persisted contents", {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NewlineSaveUndo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let f = try EditorCheckFixture("Original\n")
            f.action { f.type("Saved ") }
            let savedSource = f.document.source
            var completed = false
            var saveError: Error?
            f.document.save(to: directory.appendingPathComponent("Note.md"), ofType: "net.daringfireball.markdown", for: .saveAsOperation) { error in
                saveError = error; completed = true
            }
            let deadline = Date().addingTimeInterval(3)
            while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            try require(completed && saveError == nil, "Native save failed or did not complete: \(String(describing: saveError))")
            try require(!f.document.isDocumentEdited, "Successful save left document dirty; source matches: \(f.document.source == savedSource), draft: \(f.document.isDraft), URL: \(String(describing: f.document.fileURL)), una-autosaved: \(f.document.hasUnautosavedChanges)")
            f.action { f.type("Changed ") }
            try require(f.document.isDocumentEdited, "Edit after saving did not mark document dirty")
            f.document.undoManager?.undo()
            try require(f.document.source == savedSource && !f.document.isDocumentEdited, "Undo to saved content did not restore clean state")
            f.document.undoManager?.undo()
            try require(f.document.source == "Original\n" && f.document.isDocumentEdited, "Undo past saved content did not retain dirty state; source: \(f.document.source), edited: \(f.document.isDocumentEdited)")
            f.document.undoManager?.redo()
            try require(f.document.source == savedSource && !f.document.isDocumentEdited, "Redo to saved content did not restore clean state")
        }),
        ("UTF-8 validation and untouched file bytes", {
            let f = try EditorCheckFixture("# Äpfel\r\n\r\nOriginal  text\r\n")
            let data = try f.document.data(ofType: "net.daringfireball.markdown")
            try require(data == Data("# Äpfel\r\n\r\nOriginal  text\r\n".utf8), "Unchanged document bytes were normalized")
            do {
                try f.document.read(from: Data([0xFF, 0xFE, 0xFA]), ofType: "net.daringfireball.markdown")
                throw NSError(domain: "Newline.IntegrationChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 was silently accepted"])
            } catch let error as NSError {
                try require(error.domain == NSCocoaErrorDomain, "Invalid UTF-8 did not produce the expected read error")
            }
        }),
        ("100k document render and native editing", {
            let unit = "A paragraph with **bold**, [a link](https://example.com), and ordinary text.\n\n"
            let source = String(String(repeating: unit, count: 1500).prefix(100_000))
            let start = Date.timeIntervalSinceReferenceDate
            let f = try EditorCheckFixture(source)
            let rendered = Date.timeIntervalSinceReferenceDate
            f.text.setSelectedRange(NSRange(location: 0, length: 0))
            f.action { f.type("X") }
            let edited = Date.timeIntervalSinceReferenceDate
            print(String(format: "BENCHMARK 100k Markdown: render %.1f ms, native edit+serialize+metrics %.1f ms", (rendered - start) * 1000, (edited - rendered) * 1000))
            print(String(format: "PROFILE: serialization %.1f ms, footnotes %.1f ms, last metrics %.1f ms", f.session.lastSerializationTime * 1000, f.session.lastFootnoteTime * 1000, f.session.lastStatisticsTime * 1000))
            try require(f.document.source.hasPrefix("X"), "Large-document edit was lost")
        })
    ]
    var failures: [String] = []
    var passed = 0
    for (name, test) in tests {
        do { try test(); passed += 1; print("PASS \(name)") }
        catch { failures.append("\(name): \(error.localizedDescription)"); print("FAIL \(name): \(error.localizedDescription)") }
    }
    if !failures.isEmpty {
        throw NSError(domain: "Newline.IntegrationChecks", code: failures.count,
                      userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
    }
    return passed
}

@MainActor
private final class EditorCheckFixture {
    let document: MarkdownDocument
    let session: EditorSession
    let text: NewlineTextView

    init(_ source: String = "", fileURL: URL? = nil) throws {
        if let fileURL {
            document = try MarkdownDocument(contentsOf: fileURL, ofType: "net.daringfireball.markdown")
        } else {
            document = MarkdownDocument()
            try document.read(from: Data(source.utf8), ofType: "net.daringfireball.markdown")
        }
        session = EditorSession(document: document)
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 680, height: 100_000))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        text = NewlineTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 680), textContainer: container)
        text.session = session
        text.isRichText = true
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        session.attach(text)
        document.onSourceReload = { [weak session] source in session?.reload(source) }
        document.undoManager?.removeAllActions()
        document.undoManager?.groupsByEvent = false
        document.updateChangeCount(.changeCleared)
    }

    func action(_ body: () -> Void) {
        text.breakUndoCoalescing()
        document.undoManager?.beginUndoGrouping()
        body()
        document.undoManager?.endUndoGrouping()
        text.breakUndoCoalescing()
    }

    func type(_ value: String) {
        text.insertText(value, replacementRange: text.selectedRange())
    }
}
