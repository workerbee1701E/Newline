import AppKit
import SwiftUI

@MainActor
final class ShortcutHelp: NSObject {
    static let shared = ShortcutHelp()
    private var panel: NSPanel?

    static func isHelpShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        return event.type == .keyDown && modifiers == [.command, .shift] && event.characters == "?"
    }

    @objc func show(_ sender: Any?) {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let window = ShortcutPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Tastaturkürzel"
        window.minSize = NSSize(width: 440, height: 360)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ShortcutHelpView())
        window.center()
        panel = window
        window.makeKeyAndOrderFront(nil)
    }
}

private final class ShortcutPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

private struct ShortcutHelpView: View {
    private let groups: [(String, [(String, String)])] = [
        ("Dateien", [("Neues Dokument", "⌘N"), ("Öffnen", "⌘O"), ("Speichern", "⌘S"),
                     ("Sichern unter", "⌥⇧⌘S"), ("Fenster schließen", "⌘W"), ("Fenster minimieren", "⌘M"),
                     ("Newline ausblenden", "⌘H"), ("Andere Apps ausblenden", "⌥⌘H"), ("Newline beenden", "⌘Q")]),
        ("Bearbeiten", [("Rückgängig / Wiederholen", "⌘Z / ⇧⌘Z"), ("Ausschneiden / Kopieren / Einsetzen", "⌘X / ⌘C / ⌘V"),
                         ("Als einfachen Text einsetzen", "⌥⇧⌘V"), ("Alles auswählen", "⌘A")]),
        ("Suchen", [("Suchen", "⌘F"), ("Suchen und Ersetzen", "⌥⌘F"), ("Nächster / vorheriger Treffer", "⌘G / ⇧⌘G"),
                      ("Auswahl als Suchbegriff", "⌘E"), ("Suche schließen", "Esc")]),
        ("Formatieren", [("Fett / Kursiv", "⌘B / ⌘I"), ("Link bearbeiten", "⌘K"), ("Durchstreichen", "⇧⌘X"),
                          ("Inline-Code", "⇧⌘C"), ("Überschrift 1–6", "⌥⌘1–6"), ("Normaler Absatz", "⌥⌘0"),
                          ("Nummerierte Liste / Aufzählung", "⇧⌘7 / ⇧⌘8")]),
        ("Darstellung", [("Schrift größer / kleiner", "⌘+ / ⌘−"), ("Standardschriftgröße", "⌘0"),
                          ("Gliederung ein-/ausblenden", "⌃⌘S"), ("Vollbild", "⌃⌘F"),
                          ("Tastaturkürzel anzeigen", "⌘⇧?"), ("Diese Übersicht schließen", "Esc")]),
        ("Navigation", [("Vorherige / nächste Tabellenzelle", "⇧Tab / Tab"),
                         ("Liste einrücken / ausrücken", "Tab / ⇧Tab"),
                         ("Wortweise bewegen", "⌥← / ⌥→"), ("Zeilenanfang / -ende", "⌘← / ⌘→"),
                         ("Dokumentanfang / -ende", "⌘↑ / ⌘↓"), ("Auswahl beim Navigieren erweitern", "+ ⇧")])
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Tastaturkürzel").font(.system(size: 25, weight: .semibold))
                ForEach(groups.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(groups[index].0).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(groups[index].1.indices, id: \.self) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 16) {
                                Text(groups[index].1[row].0).frame(maxWidth: .infinity, alignment: .leading)
                                Text(groups[index].1[row].1).font(.system(size: 13, weight: .medium, design: .monospaced))
                            }.font(.system(size: 13))
                        }
                    }
                }
                Text("⌘ Command · ⌥ Option · ⇧ Shift · ⌃ Control\nWeitere Strukturaktionen findest du unter Einfügen und Format.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
