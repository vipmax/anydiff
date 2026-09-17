import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import AnyDiffCore
@testable import AnyDiffUI

final class ImageAttachmentHelpersTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("image_helpers_tests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func createTestPNGImage(width: Int = 100, height: Int = 100) -> (NSImage, Data) {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Failed to create test PNG data")
        }
        return (image, pngData)
    }

    func testDeduplicateAttachmentsWithDualRepresentation() {
        let (_, pngData) = createTestPNGImage(width: 200, height: 150)

        let fileAttachment = AgentImageAttachment(
            data: pngData,
            filePath: "/Users/test/Desktop/Screenshot 2026-09-17 at 19.47.45.png",
            mimeType: "image/png",
            filename: "Screenshot 2026-09-17 at 19.47.45.png",
            width: 200,
            height: 150,
            fileSize: pngData.count
        )

        let rawDropAttachment = AgentImageAttachment(
            data: pngData,
            filePath: "/tmp/dropped_image_1.png",
            mimeType: "image/png",
            filename: "dropped_image_1.png",
            width: 200,
            height: 150,
            fileSize: pngData.count
        )

        // Case 1: file first, generic second
        let dedup1 = ImageAttachmentHelpers.deduplicateAttachments([fileAttachment, rawDropAttachment])
        XCTAssertEqual(dedup1.count, 1)
        XCTAssertEqual(dedup1.first?.filename, "Screenshot 2026-09-17 at 19.47.45.png")

        // Case 2: generic first, file second (should replace generic with named file)
        let dedup2 = ImageAttachmentHelpers.deduplicateAttachments([rawDropAttachment, fileAttachment])
        XCTAssertEqual(dedup2.count, 1)
        XCTAssertEqual(dedup2.first?.filename, "Screenshot 2026-09-17 at 19.47.45.png")
    }

    func testDeduplicateAttachmentsPreservesDistinctImages() {
        let (_, data1) = createTestPNGImage(width: 100, height: 100)
        let (_, data2) = createTestPNGImage(width: 200, height: 200)

        let att1 = AgentImageAttachment(
            data: data1,
            filePath: "/tmp/img1.png",
            mimeType: "image/png",
            filename: "img1.png",
            width: 100,
            height: 100,
            fileSize: data1.count
        )

        let att2 = AgentImageAttachment(
            data: data2,
            filePath: "/tmp/img2.png",
            mimeType: "image/png",
            filename: "img2.png",
            width: 200,
            height: 200,
            fileSize: data2.count
        )

        let dedup = ImageAttachmentHelpers.deduplicateAttachments([att1, att2])
        XCTAssertEqual(dedup.count, 2)
    }

    func testExtractImagesFromPasteboardWithDualFileURLAndBitmapData() {
        let (_, pngData) = createTestPNGImage(width: 120, height: 80)
        let fileURL = tempDir.appendingPathComponent("Screenshot 2026-09-17 at 19.47.45.png")
        try? pngData.write(to: fileURL)

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()

        // Simulate macOS screenshot drag: pasteboard has BOTH file URL and raw PNG data
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setData(pngData, forType: NSPasteboard.PasteboardType("public.png"))
        pb.writeObjects([fileURL as NSURL, item])

        let attachments = ImageAttachmentHelpers.extractImages(from: pb)

        // Should only extract ONE attachment, not two!
        XCTAssertEqual(attachments.count, 1, "Dual representation in pasteboard should only extract 1 image")
        XCTAssertEqual(attachments.first?.filename, "Screenshot 2026-09-17 at 19.47.45.png")
    }

    func testHasImagesInPasteboard() {
        let pbEmpty = NSPasteboard.withUniqueName()
        pbEmpty.clearContents()
        pbEmpty.setString("Just plain text", forType: .string)
        XCTAssertFalse(ImageAttachmentHelpers.hasImages(in: pbEmpty))

        let pbImage = NSPasteboard.withUniqueName()
        pbImage.clearContents()
        let (_, pngData) = createTestPNGImage()
        pbImage.setData(pngData, forType: .png)
        XCTAssertTrue(ImageAttachmentHelpers.hasImages(in: pbImage))
    }

    func testDeduplicatePreservesDifferentImagesWithSameDimensions() {
        // Two distinct images with the EXACT same pixel dimensions (150x150)
        // One is a dropped image with generic name, the other is a distinct photo file
        let (_, data1) = createTestPNGImage(width: 150, height: 150)

        // Create a different image by drawing a distinctive rect
        let image2 = NSImage(size: NSSize(width: 150, height: 150))
        image2.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 75, height: 75).fill()
        NSColor.blue.setFill()
        NSRect(x: 75, y: 75, width: 75, height: 75).fill()
        image2.unlockFocus()
        guard let tiff2 = image2.tiffRepresentation,
              let rep2 = NSBitmapImageRep(data: tiff2),
              let data2 = rep2.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to create test image 2")
            return
        }

        XCTAssertNotEqual(data1, data2, "Data of distinct images must not be equal")

        let attGeneric = AgentImageAttachment(
            data: data1,
            filePath: "/tmp/dropped_image_1.png",
            mimeType: "image/png",
            filename: "dropped_image_1.png",
            width: 150,
            height: 150,
            fileSize: data1.count
        )

        let attNamedFile = AgentImageAttachment(
            data: data2,
            filePath: "/Users/test/Desktop/different_photo.png",
            mimeType: "image/png",
            filename: "different_photo.png",
            width: 150,
            height: 150,
            fileSize: data2.count
        )

        // Must keep BOTH distinct images even though they share the same 150x150 dimensions!
        let dedup = ImageAttachmentHelpers.deduplicateAttachments([attGeneric, attNamedFile])
        XCTAssertEqual(dedup.count, 2, "Distinct images with same dimensions must never be discarded")
    }

    func testDeduplicatePreservesDifferentImagesWithSameFileSize() {
        let dummyData1 = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03, 0x04])
        let dummyData2 = Data([0x89, 0x50, 0x4E, 0x47, 0x04, 0x03, 0x02, 0x01])

        XCTAssertEqual(dummyData1.count, dummyData2.count)
        XCTAssertNotEqual(dummyData1, dummyData2)

        let att1 = AgentImageAttachment(
            data: dummyData1,
            filePath: "/tmp/imgA.png",
            mimeType: "image/png",
            filename: "imgA.png",
            width: 100,
            height: 100,
            fileSize: dummyData1.count
        )

        let att2 = AgentImageAttachment(
            data: dummyData2,
            filePath: "/tmp/imgB.png",
            mimeType: "image/png",
            filename: "imgB.png",
            width: 100,
            height: 100,
            fileSize: dummyData2.count
        )

        let dedup = ImageAttachmentHelpers.deduplicateAttachments([att1, att2])
        XCTAssertEqual(dedup.count, 2, "Distinct images with same file size and dimensions must not be discarded")
    }

    func testExtractImagesFromPasteboardWithFilenamesPboardType() {
        let (_, pngData) = createTestPNGImage(width: 80, height: 80)
        let fileURL = tempDir.appendingPathComponent("finder_dragged.png")
        try? pngData.write(to: fileURL)

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.declareTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")], owner: nil)
        pb.setPropertyList([fileURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        XCTAssertTrue(ImageAttachmentHelpers.hasImages(in: pb))

        let attachments = ImageAttachmentHelpers.extractImages(from: pb)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.filename, "finder_dragged.png")
    }

    func testAgentInputCustomTextViewTextSystemAndTyping() {
        let textView = AgentInputCustomTextView()
        textView.setupDragDrop()

        // 1. Verify text system is fully configured (not bypassed or nil)
        XCTAssertNotNil(textView.textContainer, "AgentInputCustomTextView must have a valid textContainer")
        XCTAssertNotNil(textView.layoutManager, "AgentInputCustomTextView must have a valid layoutManager")
        XCTAssertNotNil(textView.textStorage, "AgentInputCustomTextView must have a valid textStorage")

        // 2. Verify typing works
        textView.isEditable = true
        textView.insertText("Hello agent!", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.string, "Hello agent!")

        // 3. Verify onSend callback on Enter key
        var sendCalled = false
        textView.onSend = { sendCalled = true }

        let enterEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36 // Enter
        )!
        textView.keyDown(with: enterEvent)
        XCTAssertTrue(sendCalled, "Enter key without modifiers must trigger onSend")
    }
}
