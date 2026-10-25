import XCTest
import AppKit
import SwiftUI
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

    func testInputAndCellLineSpacingMatchExactLineFragmentPositions() {
        let text = "Line 1\nLine 2\nLine 3"

        // 1. Configure input text view
        let textView = AgentInputCustomTextView()
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = 3
        paraStyle.paragraphSpacing = 0
        textView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textView.customParagraphStyle = paraStyle
        textView.defaultParagraphStyle = paraStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .paragraphStyle: paraStyle
        ]
        textView.string = text
        let tc1 = textView.textContainer!
        tc1.lineFragmentPadding = 0
        let lm1 = textView.layoutManager!
        lm1.ensureLayout(for: tc1)

        var inputOrigins: [CGFloat] = []
        lm1.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: (textView.string as NSString).length)) { rect, _, _, _, _ in
            inputOrigins.append(rect.origin.y)
        }

        // 2. Configure message cell
        let message = AgentMessage(role: .user, content: text)
        let cell = AgentMessageCell(message: message, theme: .zedDark)
        _ = cell.layout(for: 400)

        guard let tv = cell.userContentViews.first as? AgentSelectableTextView,
              let _ = tv.textContainer,
              let lm2 = tv.layoutManager else {
            XCTFail("AgentMessageCell should have an AgentSelectableTextView in userContentViews")
            return
        }

        var cellOrigins: [CGFloat] = []
        lm2.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: (tv.string as NSString).length)) { rect, _, _, _, _ in
            cellOrigins.append(rect.origin.y)
        }

        XCTAssertEqual(inputOrigins.count, 3)
        XCTAssertEqual(cellOrigins.count, 3)
        XCTAssertEqual(inputOrigins, cellOrigins, "Line spacing and Y origins must match exactly between input and message cell")
    }

    func testMeasureUserAndAgentCellHeights() {
        let text = "куку бро"
        let userMsg = AgentMessage(role: .user, content: text)
        let scrollView = AgentChatScrollView(frame: .zero)
        scrollView.update(messages: [userMsg], theme: .zedDark, animated: false)

        guard let cell = scrollView.documentView?.subviews.compactMap({ $0 as? AgentMessageCell }).first,
              let tv = cell.userContentViews.first as? AgentSelectableTextView else {
            XCTFail("no cell or tv")
            return
        }
        var lines0 = 0
        tv.layoutManager?.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: (tv.string as NSString).length)) { _, _, _, _, _ in
            lines0 += 1
        }
        print("AFTER MAKE: lines=\(lines0), tv.frame=\(tv.frame)")

        scrollView.setFrameSize(NSSize(width: 400, height: 600))
        var lines1 = 0
        tv.layoutManager?.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: (tv.string as NSString).length)) { _, _, _, _, _ in
            lines1 += 1
        }
        print("AFTER setFrameSize(400) SYNCHRONOUSLY: lines=\(lines1), tv.frame=\(tv.frame)")
        XCTAssertEqual(lines0, 1, "Must be 1 line immediately upon update even before frame is set")
        XCTAssertEqual(lines1, 1, "Must be 1 line immediately upon setFrameSize without waiting for async debounce")

        let cell2 = scrollView.documentView?.subviews.compactMap({ $0 as? AgentMessageCell }).first!
        XCTAssertEqual(cell2?.layout(for: 1400), cell2?.layout(for: 1400))
        XCTAssertEqual(AgentMessageCell.maxContentWidth, 800)
        XCTAssertEqual(AgentMessageCell.contentWidth(for: 1400), 800)

        // Debug exact frames from user screenshot
        let m1 = AgentMessage(role: .user, content: "броо")
        let m2 = AgentMessage(role: .assistant, content: "Привет, бро! 👋 Чем могу помочь? Есть задача по коду или что-то нужно разобрать?")
        let m3 = AgentMessage(role: .user, content: "куку бро")
        let m4 = AgentMessage(role: .assistant, content: "Ку-ку! На связи. Рассказывай, что пилим или чиним? 🚀")

        let sv = AgentChatScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let agentId = "antigravity-acp-djvipmax"

        sv.setInputView(AnyView(Text("Input")), inputHeight: 58)
        sv.update(messages: [m1, m2, m3, m4], theme: .zedDark, agentId: agentId, animated: false)
        sv.setFrameSize(NSSize(width: 800, height: 600))

        let doc = sv.documentView as! AgentChatDocumentView
        var prevBottom: CGFloat = 0
        let sortedViews = doc.subviews.sorted(by: { $0.frame.origin.y < $1.frame.origin.y })
        for sub in sortedViews {
            if let cell = sub as? AgentMessageCell {
                let roleTop = cell.frame.origin.y + cell.roleIconView.frame.origin.y
                let roleBottom = roleTop + cell.roleIconView.frame.height
                if prevBottom > 0 {
                    XCTAssertEqual(roleTop - prevBottom, 22, accuracy: 0.5, "Inter-message avatar gaps must be 22 pt")
                }
                prevBottom = roleBottom
            } else if sub is NSHostingView<AnyView> {
                let inputTop = sub.frame.origin.y + 2
                XCTAssertEqual(inputTop - prevBottom, 22, accuracy: 0.5, "Input avatar gap from last message avatar must be 22 pt")
            }
        }
    }

    func testAvatarZoomAndIconSizeSettings() {
        var settings = AvatarSettings()
        settings.zoom = 5.0
        settings.userAvatarSize = 50
        settings.agentAvatarSize = 50
        settings.agentZoom = 5.0

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        guard let data = try? encoder.encode(settings),
              let decoded = try? decoder.decode(AvatarSettings.self, from: data) else {
            XCTFail("Failed to encode/decode AvatarSettings")
            return
        }

        XCTAssertEqual(decoded.zoom, 5.0)
        XCTAssertEqual(decoded.userAvatarSize, 50)
        XCTAssertEqual(decoded.agentAvatarSize, 50)
        XCTAssertEqual(decoded.agentZoom, 5.0)

        let editor = AgentAvatarEditorView(onDismiss: {})
        XCTAssertNotNil(editor)

        // Verify focal point invariance on zoom scaling
        let initialZoom: CGFloat = 2.0
        let initialOffset = CGSize(width: 50.0, height: 80.0)
        let newZoom: CGFloat = 4.0
        let scale = newZoom / initialZoom
        let scaledOffset = CGSize(width: initialOffset.width * scale, height: initialOffset.height * scale)

        // Focal point relative to image center: -offset / (baseScale * zoom)
        let baseScale: CGFloat = 0.05
        let focalX1 = -initialOffset.width / (baseScale * initialZoom)
        let focalY1 = -initialOffset.height / (baseScale * initialZoom)
        let focalX2 = -scaledOffset.width / (baseScale * newZoom)
        let focalY2 = -scaledOffset.height / (baseScale * newZoom)

        XCTAssertEqual(focalX1, focalX2, accuracy: 0.0001, "Focal point in image center must remain stationary when zooming")
        XCTAssertEqual(focalY1, focalY2, accuracy: 0.0001, "Focal point in image center must remain stationary when zooming")
    }

    func testSingleLineMessageDisablesStickyAvatar() {
        let theme = Theme.vesper
        let userSingle = AgentMessage(id: UUID(), role: .user, content: "куку")
        let cellSingle = AgentMessageCell(message: userSingle, theme: theme)
        let singleH = cellSingle.layout(for: 600)
        cellSingle.frame = NSRect(x: 0, y: 0, width: 600, height: singleH)
        cellSingle.applyLayout(for: 600, animated: false)

        XCTAssertTrue(cellSingle.isSingleLineMessage, "Short message without newlines must be detected as single-line")

        // Try to trigger sticky avatar with a large viewport scroll offset
        let initialY = cellSingle.roleIconView.frame.origin.y
        cellSingle.updateStickyAvatar(viewportTopInDocument: 200)
        XCTAssertEqual(cellSingle.roleIconView.frame.origin.y, initialY, "Single line message avatar must not move or stick")

        // Multi-line user message
        let userMulti = AgentMessage(id: UUID(), role: .user, content: "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7")
        let cellMulti = AgentMessageCell(message: userMulti, theme: theme)
        let multiH = cellMulti.layout(for: 600)
        cellMulti.frame = NSRect(x: 0, y: 0, width: 600, height: multiH)
        cellMulti.applyLayout(for: 600, animated: false)

        XCTAssertFalse(cellMulti.isSingleLineMessage, "Multi-line message must not be detected as single line")
        cellMulti.updateStickyAvatar(viewportTopInDocument: 80)
        XCTAssertGreaterThan(cellMulti.roleIconView.frame.origin.y, cellMulti.stickyAvatarBaseY, "Multi-line message avatar must stick when scrolled")

        // Single line assistant message
        let assistantSingle = AgentMessage(id: UUID(), role: .assistant, content: "Готов к задачам!")
        let cellAssistantSingle = AgentMessageCell(message: assistantSingle, theme: theme)
        let asstH = cellAssistantSingle.layout(for: 600)
        cellAssistantSingle.frame = NSRect(x: 0, y: 0, width: 600, height: asstH)
        cellAssistantSingle.applyLayout(for: 600, animated: false)

        XCTAssertTrue(cellAssistantSingle.isSingleLineMessage, "Short assistant message without newlines/tools must be single line")
        let assistantInitialY = cellAssistantSingle.roleIconView.frame.origin.y
        cellAssistantSingle.updateStickyAvatar(viewportTopInDocument: 200)
        XCTAssertEqual(cellAssistantSingle.roleIconView.frame.origin.y, assistantInitialY, "Single line assistant avatar must not move or stick")
    }
}
