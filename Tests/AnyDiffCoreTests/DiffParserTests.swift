import XCTest
@testable import AnyDiffCore

final class DiffParserTests: XCTestCase {
    func testUnifiedDiffParsing() {
        let diff = """
diff --git a/App.swift b/App.swift
index 1111111..2222222 100644
--- a/App.swift
+++ b/App.swift
@@ -10,4 +10,5 @@ struct App {
     var count: Int
-    func run() {
+    func runAsync() async {
+        print("running")
     }
 }
"""
        let files = GitDiffParser.shared.parse(diffText: diff)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertEqual(file.displayPath, "App.swift")
        XCTAssertEqual(file.hunks.count, 1)

        let hunk = file.hunks[0]
        XCTAssertEqual(hunk.oldRange, 10..<14)
        XCTAssertEqual(hunk.newRange, 10..<15)
        XCTAssertEqual(hunk.addedLineCount, 2)
        XCTAssertEqual(hunk.deletedLineCount, 1)
    }
}
