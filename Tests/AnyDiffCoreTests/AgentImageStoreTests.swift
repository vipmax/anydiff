import XCTest
@testable import AnyDiffCore

final class AgentImageStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: AgentImageStore!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agent_store_tests_\(UUID().uuidString)")
        store = AgentImageStore(customCacheDirectory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSaveAndLazyLoadImage() {
        let sampleBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03]
        let sampleData = Data(sampleBytes)

        let attachment = store.save(
            data: sampleData,
            mimeType: "image/png",
            filename: "screenshot.png",
            width: 1920,
            height: 1080
        )

        XCTAssertNotNil(attachment.filePath)
        XCTAssertEqual(attachment.filename, "screenshot.png")
        XCTAssertEqual(attachment.width, 1920)
        XCTAssertEqual(attachment.height, 1080)
        XCTAssertEqual(attachment.fileSize, sampleData.count)
        XCTAssertEqual(attachment.fileSizeDescription, "12 B")

        // Test file actually exists on disk
        if let path = attachment.filePath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let loaded = store.loadData(at: path)
            XCTAssertEqual(loaded, sampleData)
        }

        // Test lazy loading from disk when memory data is not stored
        let diskOnlyAttachment = AgentImageAttachment(
            id: attachment.id,
            filePath: attachment.filePath,
            mimeType: attachment.mimeType,
            filename: attachment.filename,
            width: attachment.width,
            height: attachment.height,
            fileSize: attachment.fileSize
        )

        XCTAssertEqual(diskOnlyAttachment.data, sampleData)
        XCTAssertEqual(diskOnlyAttachment.base64String, sampleData.base64EncodedString())
    }

    func testDeleteAttachment() {
        let sampleData = Data("sample_image_data".utf8)
        let attachment = store.save(data: sampleData, mimeType: "image/jpeg")

        guard let path = attachment.filePath else {
            XCTFail("Missing filePath")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        store.delete(at: path)

        // Allow async barrier queue to complete
        let exp = expectation(description: "Deleted file")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testClearAllCache() {
        let sampleData1 = Data("img1".utf8)
        let sampleData2 = Data("img2".utf8)

        let a1 = store.save(data: sampleData1)
        let a2 = store.save(data: sampleData2)

        guard let p1 = a1.filePath, let p2 = a2.filePath else {
            XCTFail("Missing paths")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: p1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: p2))

        store.clearAll()

        let exp = expectation(description: "Cleared all")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: p1))
            XCTAssertFalse(FileManager.default.fileExists(atPath: p2))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testCacheLimitEvictionOldestFilesFirst() {
        let testStoreDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lru_eviction_\(UUID().uuidString)")
        // Limit to 100 bytes
        let smallStore = AgentImageStore(customCacheDirectory: testStoreDir, maxCacheSizeBytes: 100)

        // Create 3 files of 40 bytes each: total 120 bytes (exceeds 100 byte limit)
        let data1 = Data(repeating: 0x41, count: 40)
        let a1 = smallStore.save(data: data1, filename: "oldest.png")

        // Wait slightly so creation/modification dates differ
        Thread.sleep(forTimeInterval: 0.02)
        let data2 = Data(repeating: 0x42, count: 40)
        let a2 = smallStore.save(data: data2, filename: "middle.png")

        Thread.sleep(forTimeInterval: 0.02)
        let data3 = Data(repeating: 0x43, count: 40)
        let a3 = smallStore.save(data: data3, filename: "newest.png")

        // Enforce limit synchronously
        smallStore.enforceCacheLimitSync(limit: 100)

        guard let p1 = a1.filePath, let p3 = a3.filePath else {
            XCTFail("Missing paths")
            return
        }

        // Oldest file should be evicted
        XCTAssertFalse(FileManager.default.fileExists(atPath: p1), "Oldest file should have been evicted")
        // Newest file should still exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: p3), "Newest file should be preserved")

        XCTAssertLessThanOrEqual(smallStore.currentCacheSize(), 100)

        try? FileManager.default.removeItem(at: testStoreDir)
    }
}
