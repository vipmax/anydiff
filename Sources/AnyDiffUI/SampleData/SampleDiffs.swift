import Foundation

public struct SampleDiffs {
    public static let swiftMultiBufferDiff = """
diff --git a/Sources/AnyDiffCore/MultiBuffer/MultiBuffer.swift b/Sources/AnyDiffCore/MultiBuffer/MultiBuffer.swift
index 83a1b02..92c4f1a 100644
--- a/Sources/AnyDiffCore/MultiBuffer/MultiBuffer.swift
+++ b/Sources/AnyDiffCore/MultiBuffer/MultiBuffer.swift
@@ -14,8 +14,14 @@ public final class MultiBuffer: ObservableObject {
     public private(set) var buffers: [BufferId: Buffer] = [:]
     public private(set) var excerpts: [Excerpt] = []
+    public let undoManager: MultiBufferUndoManager
+    
+    /// High performance coordinate lookup cache
+    private var excerptOffsetCache: [Int] = []
+    @Published public private(set) var version: Int = 0

-    public init() {
+    public init(undoManager: MultiBufferUndoManager = MultiBufferUndoManager()) {
+        self.undoManager = undoManager
     }

     public func addExcerpt(_ excerpt: Excerpt) {
@@ -45,12 +51,18 @@ public final class MultiBuffer: ObservableObject {
     public func location(for mbRow: MultiBufferRow) -> ExcerptLocation? {
-        var currentMBRow = 0
-        for (idx, excerpt) in excerpts.enumerated() {
-            let count = excerpt.lineCount
-            if mbRow >= currentMBRow && mbRow < (currentMBRow + count) {
-                return ExcerptLocation(excerptIndex: idx, bufferId: excerpt.bufferId, bufferRow: excerpt.bufferRange.lowerBound + (mbRow - currentMBRow))
-            }
-            currentMBRow += count
-        }
+        guard mbRow >= 0 else { return nil }
+        var currentMBRow = 0
+        for (idx, excerpt) in excerpts.enumerated() {
+            let count = excerpt.lineCount
+            if mbRow >= currentMBRow && mbRow < (currentMBRow + count) {
+                let offsetInExcerpt = mbRow - currentMBRow
+                let bufferRow = excerpt.bufferRange.lowerBound + offsetInExcerpt
+                return ExcerptLocation(
+                    excerptIndex: idx,
+                    bufferId: excerpt.bufferId,
+                    filePath: excerpt.filePath,
+                    bufferRow: bufferRow,
+                    bufferColumn: 0
+                )
+            }
+            currentMBRow += count
+        }
         return nil
     }
diff --git a/Sources/AnyDiffUI/Editor/CustomMultiBufferEditorView.swift b/Sources/AnyDiffUI/Editor/CustomMultiBufferEditorView.swift
new file mode 100644
index 0000000..74bc102
--- /dev/null
+++ b/Sources/AnyDiffUI/Editor/CustomMultiBufferEditorView.swift
@@ -0,0 +1,28 @@
+import AppKit
+import CoreText
+import AnyDiffCore
+
+/// Custom high-speed CoreText MultiBuffer editor view
+public final class CustomMultiBufferEditorView: NSView {
+    public var displayMap: DisplayMap?
+    public var theme: Theme = .zedDark
+    public var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
+    
+    public override var isFlipped: Bool { true }
+    public override var acceptsFirstResponder: Bool { true }
+    
+    public override func draw(_ dirtyRect: NSRect) {
+        guard let context = NSGraphicsContext.current?.cgContext else { return }
+        // High speed virtualized line rendering
+        theme.background.setFill()
+        dirtyRect.fill()
+    }
+}
diff --git a/Sources/AnyDiffCore/Diff/WordDiffEngine.swift b/Sources/AnyDiffCore/Diff/WordDiffEngine.swift
index 11ab42c..33cc891 100644
--- a/Sources/AnyDiffCore/Diff/WordDiffEngine.swift
+++ b/Sources/AnyDiffCore/Diff/WordDiffEngine.swift
@@ -28,7 +28,8 @@ public final class WordDiffEngine {
     public func diffWords(oldText: String, newText: String) -> (oldDiffRanges: [Range<Int>], newDiffRanges: [Range<Int>]) {
-        let oldTokens = oldText.split(separator: " ")
-        let newTokens = newText.split(separator: " ")
+        let oldTokens = tokenize(oldText)
+        let newTokens = tokenize(newText)
         guard !oldTokens.isEmpty && !newTokens.isEmpty else { return ([], []) }
+        let lcs = computeLCS(oldTokens.map(\\.text), newTokens.map(\\.text))
         return ([], [])
     }
"""

    public static let rustZedDiff = """
diff --git a/crates/multi_buffer/src/multi_buffer.rs b/crates/multi_buffer/src/multi_buffer.rs
index e458a12..91fc332 100644
--- a/crates/multi_buffer/src/multi_buffer.rs
+++ b/crates/multi_buffer/src/multi_buffer.rs
@@ -73,6 +73,12 @@ pub struct MultiBuffer {
     snapshot: RefCell<MultiBufferSnapshot>,
     buffers: BTreeMap<BufferId, BufferState>,
+    diffs: HashMap<BufferId, DiffState>,
+    capability: Capability,
+}
+
+impl MultiBuffer {
+    pub fn new(capability: Capability) -> Self {
+        Self { capability, ..Default::default() }
+    }
 }
"""
}
