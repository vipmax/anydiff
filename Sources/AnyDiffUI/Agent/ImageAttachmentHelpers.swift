import AppKit
import Foundation
import UniformTypeIdentifiers
import AnyDiffCore

public enum ImageAttachmentHelpers {
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "bmp", "tiff", "tif", "heic", "heif", "svg", "ico", "avif"
    ]

    /// Extracts all image attachments present in the given pasteboard and caches them to disk.
    public static func extractImages(from pasteboard: NSPasteboard = .general) -> [AgentImageAttachment] {
        var attachments: [AgentImageAttachment] = []
        var processedFingerprints: Set<Int> = []

        // 1. Check for file URLs in pasteboard (e.g. copied files in Finder or dragged screenshots)
        var candidateURLs: [URL] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL] {
            candidateURLs.append(contentsOf: urls)
        }
        if candidateURLs.isEmpty, let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            candidateURLs.append(contentsOf: urls.filter { $0.isFileURL })
        }
        // Fallback for Finder drag-and-drop legacy/standard filenames type
        if candidateURLs.isEmpty, let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            candidateURLs.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
        }
        // Fallback for pasteboard items carrying .fileURL
        if candidateURLs.isEmpty, let items = pasteboard.pasteboardItems {
            for item in items {
                if let urlString = item.string(forType: .fileURL), let u = URL(string: urlString), u.isFileURL {
                    candidateURLs.append(u)
                }
            }
        }

        for url in candidateURLs {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let isSupportedExt = supportedImageExtensions.contains(ext)
            if (isSupportedExt || ext.isEmpty),
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: data) {
                let fingerprint = data.count ^ (ext.isEmpty ? data.prefix(32).hashValue : ext.hashValue)
                if !processedFingerprints.contains(fingerprint) {
                    processedFingerprints.insert(fingerprint)
                    let mimeType = ext.isEmpty ? "image/png" : mimeTypeForExtension(ext)
                    let size = imagePixelSize(image: image, data: data)
                    let normalizedData = normalizedImageData(from: image, fallbackData: data, preferredMimeType: mimeType)
                    let filename = url.lastPathComponent.isEmpty ? "image.png" : url.lastPathComponent
                    let attachment = AgentImageStore.shared.save(
                        data: normalizedData,
                        mimeType: mimeType,
                        filename: filename,
                        width: Double(size.width),
                        height: Double(size.height)
                    )
                    attachments.append(attachment)
                }
            }
        }

        // If file URL images were found, we are done.
        // On macOS (especially with floating screenshot thumbnails), the pasteboard provides
        // BOTH the file URL AND raw bitmap representations (PNG/TIFF) for the same screenshot.
        // Processing raw items after file URLs would duplicate the screenshot.
        if !attachments.isEmpty {
            return deduplicateAttachments(attachments)
        }

        // 2. Check for direct image pasteboard items (e.g. screenshots from clipboard or browser drop)
        if let items = pasteboard.pasteboardItems {
            for (index, item) in items.enumerated() {
                var itemData: Data? = nil
                var itemMimeType = "image/png"
                var detectedExt: String? = nil

                // Try PNG
                if let pngType = NSPasteboard.PasteboardType("public.png") as NSPasteboard.PasteboardType?,
                   let data = item.data(forType: pngType) {
                    itemData = data
                    itemMimeType = "image/png"
                    detectedExt = "png"
                } else if let pngData = item.data(forType: .png) {
                    itemData = pngData
                    itemMimeType = "image/png"
                    detectedExt = "png"
                } else if let tiffData = item.data(forType: .tiff) {
                    if let img = NSImage(data: tiffData),
                       let pngData = convertToPNGData(image: img) {
                        itemData = pngData
                        itemMimeType = "image/png"
                        detectedExt = "png"
                    } else {
                        itemData = tiffData
                        itemMimeType = "image/tiff"
                        detectedExt = "tiff"
                    }
                } else if let jpegType = NSPasteboard.PasteboardType("public.jpeg") as NSPasteboard.PasteboardType?,
                          let jpegData = item.data(forType: jpegType) {
                    itemData = jpegData
                    itemMimeType = "image/jpeg"
                    detectedExt = "jpg"
                } else if let imgType = NSPasteboard.PasteboardType("public.image") as NSPasteboard.PasteboardType?,
                          let data = item.data(forType: imgType) {
                    itemData = data
                    itemMimeType = "image/png"
                    detectedExt = "png"
                }

                if let data = itemData, let image = NSImage(data: data) {
                    let fingerprint = data.count ^ itemMimeType.hashValue
                    if !processedFingerprints.contains(fingerprint) {
                        processedFingerprints.insert(fingerprint)
                        let size = imagePixelSize(image: image, data: data)
                        let filename = "image_\(index + 1).\(detectedExt ?? "png")"
                        let attachment = AgentImageStore.shared.save(
                            data: data,
                            mimeType: itemMimeType,
                            filename: filename,
                            width: Double(size.width),
                            height: Double(size.height)
                        )
                        attachments.append(attachment)
                    }
                }
            }
        }

        // 3. Fallback: direct NSImage from pasteboard if nothing was extracted yet
        if attachments.isEmpty,
           let image = NSImage(pasteboard: pasteboard),
           let pngData = convertToPNGData(image: image) {
            let size = imagePixelSize(image: image, data: pngData)
            let attachment = AgentImageStore.shared.save(
                data: pngData,
                mimeType: "image/png",
                filename: "pasted_image.png",
                width: Double(size.width),
                height: Double(size.height)
            )
            attachments.append(attachment)
        }

        return deduplicateAttachments(attachments)
    }

    /// Fast check if pasteboard contains any supported images without reading data or writing to disk cache.
    public static func hasImages(in pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]) as? [URL] {
            if urls.contains(where: { supportedImageExtensions.contains($0.pathExtension.lowercased()) }) {
                return true
            }
        }
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            if filenames.contains(where: { supportedImageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                return true
            }
        }
        if let types = pasteboard.types {
            let imageTypes: Set<NSPasteboard.PasteboardType> = [
                .png, .tiff,
                NSPasteboard.PasteboardType("public.png"),
                NSPasteboard.PasteboardType("public.jpeg"),
                NSPasteboard.PasteboardType("public.image"),
                NSPasteboard.PasteboardType("public.tiff")
            ]
            if !imageTypes.isDisjoint(with: types) {
                return true
            }
        }
        return false
    }

    /// Extracts file URLs from drag-and-drop info that point to images and caches them to disk.
    public static func extractImages(fromURLs urls: [URL]) -> [AgentImageAttachment] {
        var attachments: [AgentImageAttachment] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()
            let isSupportedExt = supportedImageExtensions.contains(ext)
            if (isSupportedExt || ext.isEmpty),
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: data) {
                let mimeType = ext.isEmpty ? "image/png" : mimeTypeForExtension(ext)
                let size = imagePixelSize(image: image, data: data)
                let normalized = normalizedImageData(from: image, fallbackData: data, preferredMimeType: mimeType)
                let filename = url.lastPathComponent.isEmpty ? "image.png" : url.lastPathComponent
                let attachment = AgentImageStore.shared.save(
                    data: normalized,
                    mimeType: mimeType,
                    filename: filename,
                    width: Double(size.width),
                    height: Double(size.height)
                )
                attachments.append(attachment)
            }
        }
        return attachments
    }

    /// Extracts images from NSItemProviders asynchronously during a SwiftUI drag & drop operation.
    public static func extractImages(from providers: [NSItemProvider], completion: @escaping ([AgentImageAttachment]) -> Void) {
        let group = DispatchGroup()
        var attachments: [AgentImageAttachment] = []
        let lock = NSLock()

        for (index, provider) in providers.enumerated() {
            group.enter()

            // Helper to try loading raw image data if file URL path fails or is unavailable
            let tryLoadImageData: (@escaping () -> Void) -> Void = { next in
                let supportedTypes: [UTType] = [
                    .png, .jpeg, .tiff, .webP, .heic, .image
                ]
                var candidateTypeId: String? = nil
                for t in supportedTypes {
                    if provider.hasItemConformingToTypeIdentifier(t.identifier) {
                        candidateTypeId = t.identifier
                        break
                    }
                }

                if let typeId = candidateTypeId {
                    provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                        if let data = data, let img = NSImage(data: data) {
                            let size = imagePixelSize(image: img, data: data)
                            let pngData = convertToPNGData(image: img) ?? data
                            let suggested = provider.suggestedName
                            let cleanName = (suggested?.isEmpty == false) ? suggested! : "dropped_image_\(index + 1).png"
                            let attachment = AgentImageStore.shared.save(
                                data: pngData,
                                mimeType: "image/png",
                                filename: cleanName.hasSuffix(".png") ? cleanName : "\(cleanName).png",
                                width: Double(size.width),
                                height: Double(size.height)
                            )
                            lock.lock()
                            attachments.append(attachment)
                            lock.unlock()
                        }
                        next()
                    }
                } else {
                    next()
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var targetURL: URL? = nil
                    if let url = item as? URL {
                        targetURL = url
                    } else if let url = item as? NSURL {
                        targetURL = url as URL
                    } else if let data = item as? Data {
                        if let u = URL(dataRepresentation: data, relativeTo: nil) {
                            targetURL = u
                        } else if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            targetURL = URL(string: str) ?? URL(fileURLWithPath: str)
                        }
                    } else if let str = item as? String {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        targetURL = URL(string: trimmed) ?? URL(fileURLWithPath: trimmed)
                    }

                    if let url = targetURL, url.isFileURL {
                        let extracted = extractImages(fromURLs: [url])
                        if !extracted.isEmpty {
                            lock.lock()
                            attachments.append(contentsOf: extracted)
                            lock.unlock()
                            group.leave()
                            return
                        }
                    }

                    // Fallback to loading data representation if fileURL failed or wasn't readable
                    tryLoadImageData {
                        group.leave()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.webP.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.heic.identifier) {
                tryLoadImageData {
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    var targetURL: URL? = nil
                    if let u = item as? URL {
                        targetURL = u
                    } else if let u = item as? NSURL {
                        targetURL = u as URL
                    } else if let str = item as? String {
                        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        targetURL = URL(string: trimmed) ?? URL(fileURLWithPath: trimmed)
                    }
                    if let url = targetURL, url.isFileURL {
                        let extracted = extractImages(fromURLs: [url])
                        if !extracted.isEmpty {
                            lock.lock()
                            attachments.append(contentsOf: extracted)
                            lock.unlock()
                            group.leave()
                            return
                        }
                    }
                    tryLoadImageData {
                        group.leave()
                    }
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(deduplicateAttachments(attachments))
        }
    }

    /// Deduplicates attachments that represent the same image (e.g. from dual file-URL and raw-data representations
    /// created by macOS when dragging floating screenshot thumbnails or copying images).
    public static func deduplicateAttachments(_ attachments: [AgentImageAttachment]) -> [AgentImageAttachment] {
        var result: [AgentImageAttachment] = []
        for att in attachments {
            let existingIdx = result.firstIndex { existing in
                // 1. Same exact attachment ID
                if att.id == existing.id {
                    return true
                }
                // 2. Same file path on disk
                if let p1 = att.filePath, let p2 = existing.filePath, !p1.isEmpty, p1 == p2 {
                    return true
                }
                // 3. Exact same data bytes
                if !att.data.isEmpty && att.data == existing.data {
                    return true
                }
                return false
            }

            if let idx = existingIdx {
                let existing = result[idx]
                // If existing has a generic auto-generated filename and att has a specific named file, upgrade to att
                if isGenericFilename(existing.filename) && !isGenericFilename(att.filename) {
                    result[idx] = att
                }
            } else {
                result.append(att)
            }
        }
        return result
    }

    private static func isGenericFilename(_ filename: String?) -> Bool {
        guard let filename else { return true }
        return filename.hasPrefix("image_") ||
               filename.hasPrefix("dropped_image_") ||
               filename == "pasted_image.png"
    }

    /// Converts an `NSImage` to PNG `Data`.
    public static func convertToPNGData(image: NSImage) -> Data? {
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }

    /// Converts an `NSImage` to JPEG `Data`.
    public static func convertToJPEGData(image: NSImage, compressionFactor: Double = 0.85) -> Data? {
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }

    /// Normalizes image data to standard PNG or JPEG.
    private static func normalizedImageData(from image: NSImage, fallbackData: Data, preferredMimeType: String) -> Data {
        if preferredMimeType == "image/jpeg", let jpegData = convertToJPEGData(image: image) {
            return jpegData
        }
        if let pngData = convertToPNGData(image: image) {
            return pngData
        }
        return fallbackData
    }

    /// Resolves actual pixel dimensions of an image.
    public static func imagePixelSize(image: NSImage, data: Data) -> CGSize {
        if let rep = NSBitmapImageRep(data: data) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return CGSize(width: Int(image.size.width), height: Int(image.size.height))
    }

    /// Maps a file extension to its MIME type.
    public static func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "bmp":
            return "image/bmp"
        case "svg":
            return "image/svg+xml"
        case "tiff", "tif":
            return "image/tiff"
        default:
            return "image/png"
        }
    }
}
