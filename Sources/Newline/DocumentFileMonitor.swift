import Foundation

/// Watch both the inode and its directory: editors commonly save by replacing
/// the file, while other writers modify the existing inode in place.
@MainActor
final class DocumentFileMonitor {
    private let url: URL
    private let onChange: () -> Void
    private var file: DispatchSourceFileSystemObject?
    private var directory: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        directory = watch(url.deletingLastPathComponent())
        file = watch(url)
    }

    deinit {
        pending?.cancel()
        file?.cancel()
        directory?.cancel()
    }

    private func watch(_ url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Reopen after replacement, including deletion followed by recreation.
            self.file?.cancel()
            self.file = self.watch(self.url)
            self.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }
}
