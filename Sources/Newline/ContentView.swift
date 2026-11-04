import SwiftUI
import AppKit
import NewlineCore

extension Notification.Name { static let newlineFontChanged = Notification.Name("newlineFontChanged") }
final class EditorPreferences: ObservableObject {
    static let shared = EditorPreferences()
    @Published var fontSize: CGFloat { didSet { UserDefaults.standard.set(Double(fontSize), forKey: "fontSize"); NotificationCenter.default.post(name: .newlineFontChanged, object: nil) } }
    @Published var countMode: String { didSet { UserDefaults.standard.set(countMode, forKey: "countMode") } }
    private init() {
        let stored = UserDefaults.standard.double(forKey: "fontSize")
        fontSize = stored == 0 ? 16 : min(32, max(12, stored))
        countMode = UserDefaults.standard.string(forKey: "countMode") ?? "words"
    }
    func changeFont(by delta: CGFloat) { fontSize = min(32, max(12, fontSize + delta)) }
}
struct OutlineHeading: Identifiable { let id: Int; let title: String; let level: Int; let range: NSRange }

struct ContentView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var preferences = EditorPreferences.shared
    @FocusState private var toolsFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            if session.outlineVisible {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Gliederung").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 16)
                    if session.headings.isEmpty {
                        Text("Deine Überschriften erscheinen hier.").font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(session.headings) { heading in
                                Button { session.navigate(to: heading.range) } label: {
                                    Text(heading.title.isEmpty ? "Ohne Titel" : heading.title)
                                        .font(.system(size: 12, weight: heading.level == 1 ? .medium : .regular))
                                        .foregroundStyle(.primary).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 7).padding(.leading, 14 + CGFloat(heading.level - 1) * 10).padding(.trailing, 12)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Zu \(heading.title)")
                            }
                        }
                    }
                }.frame(width: 220).background(Color(nsColor: .windowBackgroundColor))
                Divider()
            }
            ZStack(alignment: .topTrailing) {
                NativeEditor(session: session)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Dokumentstatistik", selection: $preferences.countMode) {
                            Text("\(session.wordCount) Wörter").tag("words")
                            Text("\(session.characterCount) Zeichen").tag("characters")
                            Text("\(session.lineCount) Zeilen").tag("lines")
                        }.pickerStyle(.inline)
                    } label: {
                        Text(countLabel).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }.menuStyle(.borderlessButton).fixedSize().menuIndicator(.hidden).help("Wörter, Zeichen oder Zeilen anzeigen")
                    Button { session.outlineVisible.toggle() } label: {
                        Image(systemName: "list.bullet.indent").font(.system(size: 13)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Gliederung (⌃⌘S)").accessibilityLabel("Gliederung ein- oder ausblenden")
                }
                .padding(.horizontal, 16).frame(height: 30)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.96))
                .opacity(session.hovering || toolsFocused || session.statisticsPinned ? 1 : 0)
                .focusable().focused($toolsFocused)
                .onHover { session.hovering = $0 }
                .accessibilityHidden(!(session.hovering || toolsFocused || session.statisticsPinned))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    private var countLabel: String {
        switch preferences.countMode {
        case "characters": return "\(session.characterCount) Zeichen"
        case "lines": return "\(session.lineCount) Zeilen"
        default: return "\(session.wordCount) Wörter"
        }
    }
}

struct NativeEditor: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = CodeLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let text = NewlineTextView(frame: NSRect(x: 0, y: 0, width: 760, height: 680), textContainer: container)
        text.session = session
        text.isRichText = true; text.importsGraphics = false
        text.isEditable = true; text.isSelectable = true; text.allowsUndo = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticLinkDetectionEnabled = false
        text.backgroundColor = .textBackgroundColor; text.insertionPointColor = .labelColor
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = text; scroll.borderType = .noBorder
        DispatchQueue.main.async { session.attach(text); text.window?.makeFirstResponder(text); text.updateInsets() }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { (view.documentView as? NewlineTextView)?.updateInsets() }
}
