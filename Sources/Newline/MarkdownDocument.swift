import AppKit
import UniformTypeIdentifiers
import NewlineCore

private final class DocumentSourceStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private var baseline = ""
    var source: String {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var savedSource: String {
        get { lock.withLock { baseline } }
        set { lock.withLock { baseline = newValue } }
    }
}

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    nonisolated private let storage = DocumentSourceStorage()
    var onSourceReload: ((String) -> Void)?
    private var saveCallbacks: [(Bool) -> Void] = []
    private var requiresExplicitSave = false
    var source: String { storage.source }

    override init() {
        super.init()
        hasUndoManager = true
    }

    nonisolated override class var autosavesInPlace: Bool { true }
    nonisolated override class var preservesVersions: Bool { true }

    override func makeWindowControllers() {
        addWindowController(NewlineWindowController(document: self))
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // AppKit adds Duplicate automatically for autosaving document apps. Its
        // untitled copy has no file URL and would lose the origin of relative
        // resources. Save As preserves those resources through our relocation path.
        if item.action == #selector(NSDocument.duplicate(_:)) { return false }
        return super.validateUserInterfaceItem(item)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        guard super.prepareSavePanel(savePanel) else { return false }
        savePanel.allowedContentTypes = [UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]
        savePanel.allowsOtherFileTypes = false
        savePanel.isExtensionHidden = false
        let name = savePanel.nameFieldStringValue.isEmpty ? (displayName ?? "Untitled") : savePanel.nameFieldStringValue
        if URL(fileURLWithPath: name).pathExtension.isEmpty { savePanel.nameFieldStringValue = name + ".md" }
        return true
    }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "Die Datei enthält keinen gültigen UTF-8-Text.",
                                     NSLocalizedRecoverySuggestionErrorKey: "Bitte speichere sie zuerst mit UTF-8-Kodierung."])
        }
        storage.source = string
        storage.savedSource = string
        DispatchQueue.main.async { [weak self] in self?.onSourceReload?(string) }
    }

    nonisolated override func data(ofType typeName: String) throws -> Data {
        Data(storage.source.utf8)
    }

    func updateSource(_ newSource: String) {
        guard newSource != storage.source else { return }
        storage.source = newSource
        // TextKit coalesces multiple keystrokes into one undo action, so counting
        // one change per text notification cannot mirror the undo stack. Compare
        // with the last persisted content when an undo/redo returns to that state.
        updateChangeCount(newSource == storage.savedSource && !requiresExplicitSave ? .changeCleared : .changeDone)
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        if change == .changeReadOtherContents { requiresExplicitSave = true }
        if change == .changeCleared { requiresExplicitSave = false }
        // NSDocument can receive a deferred undo checkpoint after a save has
        // completed. It must not re-dirty bytes which are already on disk.
        if change == .changeDone || change == .changeUndone || change == .changeRedone {
            super.updateChangeCount(!requiresExplicitSave && storage.source == storage.savedSource ? .changeCleared : .changeDone)
        } else { super.updateChangeCount(change) }
    }

    func ensureSaved(completion: @escaping (Bool) -> Void) {
        if fileURL != nil { completion(true); return }
        saveCallbacks.append(completion)
        guard saveCallbacks.count == 1 else { return }
        save(withDelegate: self, didSave: #selector(didSaveForImage(_:didSave:contextInfo:)), contextInfo: nil)
    }

    @objc private func didSaveForImage(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let callbacks = saveCallbacks
        saveCallbacks.removeAll()
        for callback in callbacks { callback(didSave && fileURL != nil) }
    }

    func importImage(data: Data, preferredName: String) throws -> String {
        guard let fileURL else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                          userInfo: [NSLocalizedDescriptionKey: "Speichere das Dokument, bevor du ein Bild einfügst."])
        }
        return try AssetStore.importImage(data: data, preferredName: preferredName, documentURL: fileURL)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let before = storage.source
        let relocated: String
        do {
            if let previousURL = fileURL,
               saveOperation == .saveAsOperation || saveOperation == .saveToOperation {
                relocated = try AssetStore.prepareRelocation(source: before, from: previousURL, to: url).source
            } else {
                relocated = before
            }
        } catch { completionHandler(error); return }
        storage.source = relocated
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            guard let self else { completionHandler(error); return }
            if error != nil || saveOperation == .saveToOperation {
                if self.storage.source == relocated { self.storage.source = before }
            } else {
                if saveOperation != .autosaveElsewhereOperation {
                    self.storage.savedSource = relocated
                    if self.storage.source == relocated { self.updateChangeCount(.changeCleared) }
                }
                if relocated != before {
                    self.undoManager?.removeAllActions()
                    self.onSourceReload?(self.storage.source)
                }
            }
            completionHandler(error)
        }
    }

    override func move(to url: URL, completionHandler: ((Error?) -> Void)? = nil) {
        guard let previousURL = fileURL else { super.move(to: url, completionHandler: completionHandler); return }
        let before = storage.source
        let relocated: String
        do {
            relocated = try AssetStore.prepareRelocation(source: before, from: previousURL, to: url).source
        } catch { completionHandler?(error); return }
        guard relocated != before else { super.move(to: url, completionHandler: completionHandler); return }

        // Persist the current contents at their original location before moving them.
        // All asset copies have already succeeded; source assets remain untouched.
        nativeSave(to: previousURL) { [weak self] error in
            guard let self else { completionHandler?(error); return }
            if let error { completionHandler?(error); return }
            self.nativeMove(to: url) { [weak self] error in
                guard let self else { completionHandler?(error); return }
                if let error { completionHandler?(error); return }
                self.storage.source = relocated
                self.nativeSave(to: url) { [weak self] writeError in
                    guard let self else { completionHandler?(writeError); return }
                    if let writeError {
                        self.storage.source = before
                        self.nativeMove(to: previousURL) { rollbackError in
                            if rollbackError == nil {
                                self.nativeSave(to: previousURL) { _ in completionHandler?(writeError) }
                            } else {
                                // Keep the original text dirty and available in the window.
                                self.updateChangeCount(.changeReadOtherContents)
                                completionHandler?(writeError)
                            }
                        }
                    } else {
                        self.undoManager?.removeAllActions()
                        self.onSourceReload?(relocated)
                        completionHandler?(nil)
                    }
                }
            }
        }
    }

    private func nativeSave(to url: URL, completion: @escaping (Error?) -> Void) {
        let writtenSource = storage.source
        super.save(to: url, ofType: fileType ?? "net.daringfireball.markdown", for: .saveOperation,
                   completionHandler: { [weak self] error in
                       if error == nil, let self {
                           self.storage.savedSource = writtenSource
                           if self.storage.source == writtenSource { self.updateChangeCount(.changeCleared) }
                       }
                       completion(error)
                   })
    }

    private func nativeMove(to url: URL, completion: @escaping (Error?) -> Void) {
        super.move(to: url, completionHandler: completion)
    }
}
