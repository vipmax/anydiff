import AppKit
import Foundation
import UniformTypeIdentifiers
import AnyDiffCore

public enum ImageAttachmentHelpers {
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "bmp", "tiff", "tif", "heic", "heif", "svg"
    ]

    /// Extracts all image attachments present in the given pasteboard and caches them to disk.
    public static func extractImages(from pasteboard: NSPasteboard = .general) -> [AgentImageAttachment] {
        var attachments: [AgentImageAttachment] = []
        var processedFingerprints: Set<Int> = []

        // 1. Check for file URLs in pasteboard (e.g. copied files in Finder)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if supportedImageExtensions.contains(ext),
                   let data = try? Data(contentsOf: url),
                   let image = NSImage(data: data) {
                    let fingerprint = data.count ^ ext.hashValue
                    if !processedFingerprints.contains(fingerprint) {
                        processedFingerprints.insert(fingerprint)
                        let mimeType = mimeTypeForExtension(ext)
                        let size = imagePixelSize(image: image, data: data)
                        let normalizedData = normalizedImageData(from: image, fallbackData: data, preferredMimeType: mimeType)
                        let attachment = AgentImageStore.shared.save(
                            data: normalizedData,
                            mimeType: mimeType,
                            filename: url.lastPathComponent,
                            width: Double(size.width),
                            height: Double(size.height)
                        )
                        attachments.append(attachment)
                    }
                }
            }
        }

        // 2. Check for direct image pasteboard items (e.g. screenshots from clipboard)
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
                    // Convert TIFF to PNG
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

        return attachments
    }

    /// Extracts file URLs from drag-and-drop info that point to images and caches them to disk.
    public static func extractImages(fromURLs urls: [URL]) -> [AgentImageAttachment] {
        var attachments: [AgentImageAttachment] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if supportedImageExtensions.contains(ext),
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: data) {
                let mimeType = mimeTypeForExtension(ext)
                let size = imagePixelSize(image: image, data: data)
                let normalized = normalizedImageData(from: image, fallbackData: data, preferredMimeType: mimeType)
                let attachment = AgentImageStore.shared.save(
                    data: normalized,
                    mimeType: mimeType,
                    filename: url.lastPathComponent,
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
            var handled = false

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
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

                    if let url = targetURL {
                        let extracted = extractImages(fromURLs: [url])
                        lock.lock()
                        attachments.append(contentsOf: extracted)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) ||
                      provider.hasItemConformingToTypeIdentifier(UTType.tiff.identifier) {
                handled = true
                let typeId = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) ? UTType.png.identifier :
                             (provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) ? UTType.jpeg.identifier : UTType.image.identifier)

                provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                    if let data = data, let img = NSImage(data: data) {
                        let size = imagePixelSize(image: img, data: data)
                        let pngData = convertToPNGData(image: img) ?? data
                        let attachment = AgentImageStore.shared.save(
                            data: pngData,
                            mimeType: "image/png",
                            filename: "dropped_image_\(index + 1).png",
                            width: Double(size.width),
                            height: Double(size.height)
                        )
                        lock.lock()
                        attachments.append(attachment)
                        lock.unlock()
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
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
                    if let url = targetURL {
                        let extracted = extractImages(fromURLs: [url])
                        lock.lock()
                        attachments.append(contentsOf: extracted)
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            if !handled {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(attachments)
        }
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
