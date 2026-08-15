import XCTest
@testable import AnyDiffCore

final class MultiBufferTests: XCTestCase {
    func testMultiBufferCoordinateMapping() {
        let buffer1 = Buffer(filePath: "FileA.swift", text: "line 0\nline 1\nline 2\nline 3")
        let buffer2 = Buffer(filePath: "FileB.swift", text: "alpha\nbeta\ngamma")

        let mb = MultiBuffer()
        mb.addBuffer(buffer1)
        mb.addBuffer(buffer2)

        let excerpt1 = Excerpt(
            bufferId: buffer1.id,
            filePath: "FileA.swift",
            bufferRange: 1..<3 // "line 1", "line 2" (2 lines)
        )
        let excerpt2 = Excerpt(
            bufferId: buffer2.id,
            filePath: "FileB.swift",
            bufferRange: 0..<2 // "alpha", "beta" (2 lines)
        )

        mb.setExcerpts([excerpt1, excerpt2])

        XCTAssertEqual(mb.lineCount, 4)

        // MB row 0 -> FileA line 1 (1-based: 2)
        let loc0 = mb.location(for: 0)
        XCTAssertNotNil(loc0)
        XCTAssertEqual(loc0?.filePath, "FileA.swift")
        XCTAssertEqual(loc0?.bufferRow, 1)
        XCTAssertEqual(loc0?.fileLineNumber, 2)
        XCTAssertEqual(mb.line(at: 0), "line 1")

        // MB row 1 -> FileA line 2
        let loc1 = mb.location(for: 1)
        XCTAssertEqual(loc1?.bufferRow, 2)
        XCTAssertEqual(mb.line(at: 1), "line 2")

        // MB row 2 -> FileB line 0
        let loc2 = mb.location(for: 2)
        XCTAssertEqual(loc2?.filePath, "FileB.swift")
        XCTAssertEqual(loc2?.bufferRow, 0)
        XCTAssertEqual(mb.line(at: 2), "alpha")

        // Inverse mapping
        let mbRow = mb.multiBufferRow(excerptIndex: 1, bufferRow: 1)
        XCTAssertEqual(mbRow, 3)
    }

    func testLiveEditingAndUndoRedo() {
        let buffer = Buffer(filePath: "Core.swift", text: "func calculate() -> Int {\n    return 42\n}")
        let mb = MultiBuffer()
        mb.addBuffer(buffer)
        let excerpt = Excerpt(bufferId: buffer.id, filePath: "Core.swift", bufferRange: 0..<3)
        mb.addExcerpt(excerpt)

        // Edit row 1 "    return 42" -> "    return 100"
        let editRange = MultiBufferPoint(row: 1, column: 11)..<MultiBufferPoint(row: 1, column: 13)
        mb.replace(range: editRange, with: "100")

        XCTAssertEqual(mb.line(at: 1), "    return 100")
        XCTAssertTrue(mb.undoManager.canUndo)

        // Undo
        if let tx = mb.undoManager.popUndo() {
            for edit in tx.edits.reversed() {
                if let buf = mb.buffer(for: edit.bufferId) {
                    buf.replace(start: edit.range.lowerBound, end: edit.range.upperBound, with: edit.oldText)
                }
            }
        }
        XCTAssertEqual(mb.line(at: 1), "    return 42")
    }
}
