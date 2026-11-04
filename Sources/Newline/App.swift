import AppKit
import SwiftUI
import NewlineCore
import OSLog

private let launchLogger = Logger(subsystem: "io.github.workerbee1701e.newline", category: "Lifecycle")

@main
struct NewlineMain {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--check") {
            do { let count = try runIntegrationChecks(); print("PASS: \(count) editor integration checks"); exit(0) }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        _ = delegate.documents
        if CommandLine.arguments.contains("--lifecycle-check") {
            print("delegate willFinish selector: \(delegate.responds(to: #selector(NSApplicationDelegate.applicationWillFinishLaunching(_:))))")
            print("delegate didFinish selector: \(delegate.responds(to: #selector(NSApplicationDelegate.applicationDidFinishLaunching(_:))))")
            print("shared document controller: \(NSDocumentController.shared === delegate.documents)")
            let document = MarkdownDocument()
            document.makeWindowControllers()
            if let controller = document.windowControllers.first, let window = controller.window {
                print("window registered: \(controller.document === document), frame: \(window.frame), content: \(String(describing: window.contentView?.frame)), title: \(window.title)")
            } else { fputs("FAIL: no native window controller\n", stderr); exit(1) }
            exit(0)
        }
        launchLogger.notice("Entering NSApplication.run; delegate retained")
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class NewlineDocumentController: NSDocumentController {
    override var defaultType: String? { "net.daringfireball.markdown" }
    override func documentClass(forType typeName: String) -> AnyClass? { MarkdownDocument.self }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let documents = NewlineDocumentController()
    private var shortcutMonitor: Any?
    func applicationWillFinishLaunching(_ notification: Notification) {
        launchLogger.notice("applicationWillFinishLaunching")
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = makeMenu()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if ShortcutHelp.isHelpShortcut(event) {
                ShortcutHelp.shared.show(nil)
                return nil
            }
            return event
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchLogger.notice("applicationDidFinishLaunching")
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            documents.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        application(sender, open: urls)
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        do {
            _ = try documents.openUntitledDocumentAndDisplay(true)
            return true
        } catch { NSApp.presentError(error); return false }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { documents.newDocument(nil); return false }
        return true
    }
    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        func menu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: name); item.submenu = sub; main.addItem(item); return sub
        }
        func item(_ menu: NSMenu, _ name: String, _ action: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], _ tag: Int = 0) {
            let item = NSMenuItem(title: name, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.tag = tag; menu.addItem(item)
        }
        let app = menu("Newline")
        item(app, "Über Newline", "orderFrontStandardAboutPanel:")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Dienste", action: nil, keyEquivalent: ""); services.submenu = NSMenu(title: "Dienste"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator()); item(app, "Newline ausblenden", "hide:", "h")
        item(app, "Andere ausblenden", "hideOtherApplications:", "h", [.command,.option])
        item(app, "Alle einblenden", "unhideAllApplications:")
        app.addItem(.separator()); item(app, "Newline beenden", "terminate:", "q")
        let file = menu("Ablage")
        item(file, "Neu", "newDocument:", "n"); item(file, "Öffnen …", "openDocument:", "o")
        file.addItem(.separator()); item(file, "Schließen", "performClose:", "w")
        item(file, "Sichern", "saveDocument:", "s"); item(file, "Sichern unter …", "saveDocumentAs:", "s", [.command,.shift,.option])
        item(file, "Umbenennen …", "renameDocument:"); item(file, "Bewegen …", "moveDocument:")
        item(file, "Zur gespeicherten Version zurückkehren …", "revertDocumentToSaved:")
        let edit = menu("Bearbeiten")
        item(edit, "Rückgängig", "undo:", "z"); item(edit, "Wiederholen", "redo:", "z", [.command,.shift])
        edit.addItem(.separator()); item(edit, "Ausschneiden", "cut:", "x"); item(edit, "Kopieren", "copy:", "c"); item(edit, "Einsetzen", "paste:", "v")
        item(edit, "Als einfachen Text einsetzen", "pasteAsPlainText:", "v", [.command,.option,.shift]); item(edit, "Alles auswählen", "selectAll:", "a")
        edit.addItem(.separator())
        item(edit, "Suchen …", "performFindPanelAction:", "f", [.command], NSTextFinder.Action.showFindInterface.rawValue)
        item(edit, "Suchen und Ersetzen …", "performFindPanelAction:", "f", [.command,.option], NSTextFinder.Action.showReplaceInterface.rawValue)
        item(edit, "Weitersuchen", "performFindPanelAction:", "g", [.command], NSTextFinder.Action.nextMatch.rawValue)
        item(edit, "Rückwärts suchen", "performFindPanelAction:", "g", [.command,.shift], NSTextFinder.Action.previousMatch.rawValue)
        item(edit, "Auswahl suchen", "performFindPanelAction:", "e", [.command], NSTextFinder.Action.setSearchString.rawValue)
        edit.addItem(.separator()); item(edit, "Rechtschreibung während der Eingabe", "toggleContinuousSpellChecking:")
        let format = menu("Format")
        item(format, "Fett", "toggleBold:", "b"); item(format, "Kursiv", "toggleItalic:", "i")
        item(format, "Durchgestrichen", "toggleStrike:", "x", [.command,.shift]); item(format, "Inline-Code", "toggleInlineCode:", "c", [.command,.shift])
        format.addItem(.separator())
        for level in 1...6 { item(format, "Überschrift \(level)", "setHeading:", String(level), [.command,.option], level) }
        item(format, "Normaler Absatz", "setHeading:", "0", [.command,.option], 0)
        format.addItem(.separator()); item(format, "Nummerierte Liste", "toggleOrderedList:", "7", [.command,.shift])
        item(format, "Aufzählung", "toggleBulletList:", "8", [.command,.shift]); item(format, "Aufgabenliste", "toggleTaskList:")
        item(format, "Aufgabe abhaken", "toggleTask:"); item(format, "Zitat", "toggleQuote:")
        let insert = menu("Einfügen")
        item(insert, "Link …", "insertLink:", "k"); item(insert, "Bild …", "insertImage:")
        item(insert, "Tabelle …", "insertTable:"); item(insert, "Fußnote", "insertFootnote:")
        item(insert, "Codeblock", "insertCodeBlock:"); item(insert, "Trennlinie", "insertRule:")
        let view = menu("Darstellung")
        item(view, "Schrift vergrößern", "increaseFont:", "+"); item(view, "Schrift verkleinern", "decreaseFont:", "-")
        item(view, "Standardschriftgröße", "resetFont:", "0")
        view.addItem(.separator()); item(view, "Gliederung ein-/ausblenden", "toggleOutline:", "s", [.command,.control])
        item(view, "Dokumentstatistik …", "showStatistics:"); item(view, "Vollbild", "toggleFullScreen:", "f", [.command,.control])
        let window = menu("Fenster"); NSApp.windowsMenu = window
        item(window, "Im Dock ablegen", "performMiniaturize:", "m"); item(window, "Zoomen", "performZoom:"); window.addItem(.separator()); item(window, "Alle nach vorne", "arrangeInFront:")
        let help = menu("Hilfe")
        let shortcuts = NSMenuItem(title: "Tastaturkürzel …", action: #selector(ShortcutHelp.show(_:)), keyEquivalent: "?")
        shortcuts.keyEquivalentModifierMask = [.command, .shift]
        shortcuts.target = ShortcutHelp.shared
        help.addItem(shortcuts)
        NSApp.helpMenu = help
        return main
    }
}

final class NewlineWindowController: NSWindowController {
    let session: EditorSession
    init(document: MarkdownDocument) {
        session = EditorSession(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 760,height: 680), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480,height: 360)
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        window.isReleasedWhenClosed = false
        super.init(window: window)
        // NSDocument.addWindowController establishes both sides of this relation.
        // Assigning document here makes AppKit believe registration already happened,
        // leaving document.windowControllers empty and preventing showWindows().
        window.contentView = NSHostingView(rootView: ContentView(session: session))
        window.center()
        document.onSourceReload = { [weak session] source in session?.reload(source) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func windowDidLoad() { super.windowDidLoad() }
    @objc func toggleOutline(_ sender: Any?) { session.outlineVisible.toggle() }
    @objc func showStatistics(_ sender: Any?) { session.statisticsPinned.toggle() }
    @objc func increaseFont(_ sender: Any?) { EditorPreferences.shared.changeFont(by: 1) }
    @objc func decreaseFont(_ sender: Any?) { EditorPreferences.shared.changeFont(by: -1) }
    @objc func resetFont(_ sender: Any?) { EditorPreferences.shared.fontSize = 16 }
}
