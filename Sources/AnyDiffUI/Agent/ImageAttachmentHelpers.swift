import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import AnyDiffCore

public enum ImageAttachmentHelpers {
    /// Maximum pixel dimension (width or height) sent to language models, matching Zed's `ANTHROPIC_SIZE_LIMIT`.
    public static let maxModelImageDimension: Int = 1568

    /// Hard per-image encoded byte limit before base64 encoding, matching Zed's `DEFAULT_IMAGE_MAX_BYTES` (5 MB).
    public static let maxModelImageBytes: Int = 5 * 1024 * 1024

    /// Maximum iterative downscale passes when an encoded PNG still exceeds `maxModelImageBytes`.
    public static let maxModelImageDownscalePasses: Int = 8

    private static let inlineThumbnailCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    /// Returns a pre-decoded, downsampled display `NSImage` and its logical bounds for inline rendering
    /// so TextKit / CoreAnimation never decodes or resamples full-resolution images during scroll.
    public static func inlineDisplayImage(
        for attachment: AgentImageAttachment,
        maxSize: NSSize = NSSize(width: 420, height: 220)
    ) -> (image: NSImage?, bounds: NSRect) {
        let key = attachment.id as NSUUID
        if let cached = inlineThumbnailCache.object(forKey: key) {
            return (cached, NSRect(origin: .zero, size: cached.size))
        }

        let rawData = attachment.data
        guard !rawData.isEmpty else {
            return (nil, NSRect(x: 0, y: 0, width: 240, height: 150))
        }

        let baseImage = NSImage(data: rawData)
        let imageSize = baseImage?.size ?? .zero
        let sourceWidth = imageSize.width > 0 ? imageSize.width : CGFloat(attachment.width ?? 0)
        let sourceHeight = imageSize.height > 0 ? imageSize.height : CGFloat(attachment.height ?? 0)
        guard sourceWidth > 0, sourceHeight > 0 else {
            return (baseImage, NSRect(x: 0, y: 0, width: 240, height: 150))
        }

        let scale = min(1, maxSize.width / sourceWidth, maxSize.height / sourceHeight)
        let targetSize = NSSize(width: sourceWidth * scale, height: sourceHeight * scale)
        let targetRect = NSRect(origin: .zero, size: targetSize)

        let maxPixelDimension = Int(ceil(max(targetSize.width, targetSize.height) * 2.0))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelDimension)
        ]

        if let source = CGImageSourceCreateWithData(rawData as CFData, nil),
           let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            let finalCG = roundedThumbnailCGImage(from: cgThumb, pointSize: targetSize, cornerRadius: 8) ?? cgThumb
            let thumbImage = NSImage(cgImage: finalCG, size: targetSize)
            inlineThumbnailCache.setObject(thumbImage, forKey: key)
            return (thumbImage, targetRect)
        }

        if let baseImage {
            if let cg = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let roundedCG = roundedThumbnailCGImage(from: cg, pointSize: targetSize, cornerRadius: 8) {
                let thumbImage = NSImage(cgImage: roundedCG, size: targetSize)
                inlineThumbnailCache.setObject(thumbImage, forKey: key)
                return (thumbImage, targetRect)
            }
            baseImage.size = targetSize
            inlineThumbnailCache.setObject(baseImage, forKey: key)
            return (baseImage, targetRect)
        }

        return (nil, targetRect)
    }

    private static func roundedThumbnailCGImage(
        from sourceCG: CGImage,
        pointSize: NSSize,
        cornerRadius: CGFloat
    ) -> CGImage? {
        let scale: CGFloat = 2.0
        let pixelW = max(2, Int(ceil(pointSize.width * scale)))
        let pixelH = max(2, Int(ceil(pointSize.height * scale)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let fullRect = CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH))
        let radius = min(cornerRadius * scale, min(fullRect.width, fullRect.height) / 2)
        let clipPath = CGPath(roundedRect: fullRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(sourceCG, in: fullRect)
        ctx.restoreGState()

        // Subtle 1pt inner border so dark images stand out against dark backgrounds
        let borderWidth = 1.0 * scale
        let strokeRect = fullRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
        let strokeRadius = max(0, radius - borderWidth / 2)
        let strokePath = CGPath(roundedRect: strokeRect, cornerWidth: strokeRadius, cornerHeight: strokeRadius, transform: nil)
        ctx.setLineWidth(borderWidth)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.addPath(strokePath)
        ctx.strokePath()

        return ctx.makeImage()
    }

    /// Copies the given image attachment to the general pasteboard eagerly as PNG data
    /// (avoiding lazy `NSImage` pasteboard promises that fail with `CGImageDestinationFinalize` once deallocated).
    public static func copyToPasteboard(_ attachment: AgentImageAttachment) {
        let data = attachment.data
        guard !data.isEmpty else { return }
        let pngData: Data
        if attachment.mimeType == "image/png" {
            pngData = data
        } else if let image = NSImage(data: data), let converted = convertToPNGData(image: image) {
            pngData = converted
        } else {
            pngData = data
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png], owner: nil)
        pb.setData(pngData, forType: .png)
    }
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
                    let filename = url.lastPathComponent.isEmpty ? "image.png" : url.lastPathComponent
                    let attachment = saveNormalizedAttachment(
                        image: image,
                        data: data,
                        preferredMimeType: mimeType,
                        filename: filename
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
                        let filename = "image_\(index + 1).\(detectedExt ?? "png")"
                        let attachment = saveNormalizedAttachment(
                            image: image,
                            data: data,
                            preferredMimeType: itemMimeType,
                            filename: filename
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
            let attachment = saveNormalizedAttachment(
                image: image,
                data: pngData,
                preferredMimeType: "image/png",
                filename: "pasted_image.png"
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
                let filename = url.lastPathComponent.isEmpty ? "image.png" : url.lastPathComponent
                let attachment = saveNormalizedAttachment(
                    image: image,
                    data: data,
                    preferredMimeType: mimeType,
                    filename: filename
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
                            let suggested = provider.suggestedName
                            let cleanName = (suggested?.isEmpty == false) ? suggested! : "dropped_image_\(index + 1).png"
                            let attachment = saveNormalizedAttachment(
                                image: img,
                                data: data,
                                preferredMimeType: "image/png",
                                filename: cleanName.hasSuffix(".png") ? cleanName : "\(cleanName).png"
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

    /// Converts an `NSImage` to PNG `Data` via a normalized 8-bit sRGB bitmap so `CGImageDestinationFinalize`
    /// never fails on wide-gamut, HDR, CMYK, or non-standard alpha formats.
    public static func convertToPNGData(image: NSImage) -> Data? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srgbCG = resizeCGImage(cg, width: max(1, cg.width), height: max(1, cg.height)),
           let data = NSBitmapImageRep(cgImage: srgbCG).representation(using: .png, properties: [:]) {
            return data
        }
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        if let cg = bitmapImage.cgImage,
           let srgbCG = resizeCGImage(cg, width: max(1, cg.width), height: max(1, cg.height)),
           let data = NSBitmapImageRep(cgImage: srgbCG).representation(using: .png, properties: [:]) {
            return data
        }
        return bitmapImage.representation(using: .png, properties: [:])
    }

    /// Converts an `NSImage` to JPEG `Data`.
    public static func convertToJPEGData(image: NSImage, compressionFactor: Double = 0.85) -> Data? {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srgbCG = resizeCGImage(cg, width: max(1, cg.width), height: max(1, cg.height)),
           let data = NSBitmapImageRep(cgImage: srgbCG).representation(using: .jpeg, properties: [.compressionFactor: compressionFactor]) {
            return data
        }
        guard let tiffRepresentation = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
    }

    /// Normalizes and downscales an image to fit provider constraints (`1568px` max dimension and `<= 5 MB` encoded size),
    /// matching Zed's `language_model_image_from_dynamic_image`.
    public static func prepareImageForAgent(
        image: NSImage,
        fallbackData: Data,
        preferredMimeType: String = "image/png"
    ) -> (data: Data, mimeType: String, pixelSize: CGSize) {
        let origSize = fastImagePixelSize(image: image, data: fallbackData)
        var currentW = Int(origSize.width)
        var currentH = Int(origSize.height)
        guard currentW > 0, currentH > 0 else {
            let normalized = normalizedImageData(from: image, fallbackData: fallbackData, preferredMimeType: preferredMimeType)
            return (normalized, preferredMimeType, origSize)
        }

        let needsDimensionDownscale = currentW > maxModelImageDimension || currentH > maxModelImageDimension

        // Fast path: already within 1568x1568, <= 5 MB, and already PNG/JPEG — zero pixel decoding!
        if !needsDimensionDownscale,
           !fallbackData.isEmpty,
           fallbackData.count <= maxModelImageBytes,
           (preferredMimeType == "image/png" || preferredMimeType == "image/jpeg") {
            return (fallbackData, preferredMimeType, CGSize(width: currentW, height: currentH))
        }

        let initialCG: CGImage?
        if needsDimensionDownscale,
           !fallbackData.isEmpty,
           let source = CGImageSourceCreateWithData(fallbackData as CFData, nil) {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxModelImageDimension
            ]
            initialCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        } else if let sourceCG = extractCGImage(image: image, data: fallbackData) {
            if needsDimensionDownscale {
                let scale = min(
                    Double(maxModelImageDimension) / Double(currentW),
                    Double(maxModelImageDimension) / Double(currentH)
                )
                let targetW = max(1, Int((Double(currentW) * scale).rounded()))
                let targetH = max(1, Int((Double(currentH) * scale).rounded()))
                initialCG = resizeCGImage(sourceCG, width: targetW, height: targetH) ?? sourceCG
            } else {
                initialCG = sourceCG
            }
        } else {
            initialCG = nil
        }

        guard var currentCG = initialCG else {
            let normalized = normalizedImageData(from: image, fallbackData: fallbackData, preferredMimeType: preferredMimeType)
            return (normalized, preferredMimeType, origSize)
        }

        currentW = currentCG.width
        currentH = currentCG.height

        let outputMime = (preferredMimeType == "image/jpeg") ? "image/jpeg" : "image/png"
        var encodedData = encodeCGImage(currentCG, mimeType: outputMime) ?? fallbackData

        for _ in 0..<maxModelImageDownscalePasses {
            if encodedData.count <= maxModelImageBytes {
                break
            }
            if currentW <= 1 || currentH <= 1 {
                break
            }
            currentW = max(1, Int((Double(currentW) * 0.85).rounded()))
            currentH = max(1, Int((Double(currentH) * 0.85).rounded()))
            guard let resized = resizeCGImage(currentCG, width: currentW, height: currentH),
                  let reencoded = encodeCGImage(resized, mimeType: outputMime) else {
                break
            }
            currentCG = resized
            encodedData = reencoded
        }

        return (encodedData, outputMime, CGSize(width: currentW, height: currentH))
    }

    private static func fastImagePixelSize(image: NSImage, data: Data) -> CGSize {
        if !data.isEmpty,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0 {
            return CGSize(width: w, height: h)
        }
        return imagePixelSize(image: image, data: data)
    }

    private static func saveNormalizedAttachment(
        image: NSImage,
        data: Data,
        preferredMimeType: String,
        filename: String
    ) -> AgentImageAttachment {
        let prepared = prepareImageForAgent(
            image: image,
            fallbackData: data,
            preferredMimeType: preferredMimeType
        )
        return AgentImageStore.shared.save(
            data: prepared.data,
            mimeType: prepared.mimeType,
            filename: filename,
            width: Double(prepared.pixelSize.width),
            height: Double(prepared.pixelSize.height)
        )
    }

    private static func extractCGImage(image: NSImage, data: Data) -> CGImage? {
        if !data.isEmpty,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return cg
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func resizeCGImage(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height)))
        return context.makeImage()
    }

    private static func encodeCGImage(_ cgImage: CGImage, mimeType: String) -> Data? {
        let normalizedCG = resizeCGImage(cgImage, width: cgImage.width, height: cgImage.height) ?? cgImage
        let rep = NSBitmapImageRep(cgImage: normalizedCG)
        if mimeType == "image/jpeg" {
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        }
        return rep.representation(using: .png, properties: [:])
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
