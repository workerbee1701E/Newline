import AppKit
import NewlineCore

@MainActor
final class NativeImageLoader {
    static let shared = NativeImageLoader()
    private let cache = NSCache<NSURL, NSImage>()
    private var tasks: Set<String> = []

    func refresh(_ text: NewlineTextView) {
        guard let storage = text.textStorage else { return }
        var sources = Set<String>()
        storage.enumerateAttribute(.newlineImageSource, in: NSRange(location: 0,length: storage.length)) { value,_,_ in
            if let value = value as? String { sources.insert(value) }
        }
        for source in sources {
            guard let url = URL(string: source), ["http","https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            if let cached = cache.object(forKey: url as NSURL) { apply(cached,source: source,to: text); continue }
            let key = "\(ObjectIdentifier(text))-\(source)"
            guard !tasks.contains(key) else { continue }
            tasks.insert(key)
            var request = URLRequest(url: url,cachePolicy: .returnCacheDataElseLoad,timeoutInterval: 20)
            request.setValue("image/*",forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: request) { [weak self, weak text] data,response,error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.tasks.remove(key)
                    guard let text, error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let data, data.count <= 20 * 1024 * 1024, let image = NSImage(data: data) else { return }
                    self.cache.setObject(image,forKey: url as NSURL)
                    self.apply(image,source: source,to: text)
                }
            }.resume()
        }
        resize(text)
    }
    private func apply(_ image: NSImage, source: String, to text: NewlineTextView) {
        guard let storage = text.textStorage else { return }
        storage.enumerateAttributes(in: NSRange(location: 0,length: storage.length)) { attrs,range,_ in
            guard attrs[.newlineImageSource] as? String == source, let attachment = attrs[.attachment] as? NSTextAttachment else { return }
            attachment.image = image
            text.layoutManager?.invalidateLayout(forCharacterRange: range,actualCharacterRange: nil)
        }
        resize(text)
        text.needsDisplay = true
    }
    func resize(_ text: NewlineTextView) {
        guard let storage = text.textStorage else { return }
        let maxWidth = max(100,(text.textContainer?.containerSize.width ?? 620) - 12)
        storage.enumerateAttribute(.attachment,in: NSRange(location: 0,length: storage.length)) { value,range,_ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image, image.size.width > 0, image.size.height > 0 else { return }
            // Keep SF Symbol missing-image placeholders compact.
            if image.isTemplate && image.size.width < 40 { return }
            let scale = min(1,min(maxWidth/image.size.width,600/image.size.height))
            let bounds = NSRect(x: 0,y: 0,width: image.size.width*scale,height: image.size.height*scale)
            if attachment.bounds != bounds {
                attachment.bounds = bounds
                text.layoutManager?.invalidateLayout(forCharacterRange: range,actualCharacterRange: nil)
            }
        }
    }
}

extension EditorSession {
    func insertRichContent(_ content: NSAttributedString) {
        var embedded: [(NSRange,NSTextAttachment)] = []
        content.enumerateAttributes(in: NSRange(location: 0,length: content.length)) { attrs,range,_ in
            if attrs[.newlineImageSource] == nil, let attachment = attrs[.attachment] as? NSTextAttachment { embedded.append((range,attachment)) }
        }
        guard !embedded.isEmpty else { insert(content); if let textView { NativeImageLoader.shared.refresh(textView) }; return }
        document?.ensureSaved { [weak self] saved in
            guard saved, let self, let document = self.document else { return }
            let imported = NSMutableAttributedString(attributedString: content)
            do {
                for (range,attachment) in embedded {
                    let name = imported.attribute(.newlineEmbeddedImageFilename, at: range.location, effectiveRange: nil) as? String ?? attachment.fileWrapper?.preferredFilename ?? "Bild.png"
                    let originalData = imported.attribute(.newlineEmbeddedImageData, at: range.location, effectiveRange: nil) as? Data
                    let data: Data
                    let filename: String
                    if let originalData, NSImage(data: originalData) != nil {
                        data = originalData; filename = name
                    } else {
                        let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
                        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png,properties: [:]) else {
                            throw NSError(domain: "Newline.ImageImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Das eingebettete Bild konnte nicht gespeichert werden. Bitte füge es als Bilddatei ein."])
                        }
                        data = png; filename = (name as NSString).deletingPathExtension + ".png"
                    }
                    let path = try document.importImage(data: data,preferredName: filename)
                    imported.addAttributes([.newlineImageSource:path,.newlineImageAlt:name],range: range)
                    imported.removeAttribute(.newlineEmbeddedImageData,range: range)
                    imported.removeAttribute(.newlineEmbeddedImageFilename,range: range)
                }
                self.insert(imported)
                if let textView = self.textView { NativeImageLoader.shared.refresh(textView) }
            } catch { NSApp.presentError(error) }
        }
    }
}
