import Foundation

/// Manages undo and redo stacks for MultiBuffer edits
public final class MultiBufferUndoManager: @unchecked Sendable {
    private static let typingCoalescingInterval: TimeInterval = 1.0
    private var undoStack: [EditTransaction] = []
    private var redoStack: [EditTransaction] = []
    private var coalescingAllowed = true
    public var maxHistory: Int = 1000

    public var canUndo: Bool {
        !undoStack.isEmpty
    }

    public var canRedo: Bool {
        !redoStack.isEmpty
    }

    public init(maxHistory: Int = 1000) {
        self.maxHistory = maxHistory
    }

    public func push(transaction: EditTransaction) {
        if coalescingAllowed,
           let previous = undoStack.last,
           canCoalesce(previous, with: transaction) {
            var merged = previous
            merged.edits.append(contentsOf: transaction.edits)
            merged.timestamp = transaction.timestamp
            merged.selectionAfter = transaction.selectionAfter
            merged.cursorAfter = transaction.cursorAfter
            merged.anchorAfter = transaction.anchorAfter
            undoStack[undoStack.count - 1] = merged
        } else {
            undoStack.append(transaction)
            if undoStack.count > maxHistory {
                undoStack.removeFirst()
            }
        }
        redoStack.removeAll()
        coalescingAllowed = true
    }

    public func popUndo() -> EditTransaction? {
        guard let transaction = undoStack.popLast() else { return nil }
        redoStack.append(transaction)
        coalescingAllowed = false
        return transaction
    }

    public func popRedo() -> EditTransaction? {
        guard let transaction = redoStack.popLast() else { return nil }
        undoStack.append(transaction)
        coalescingAllowed = false
        return transaction
    }

    private func canCoalesce(_ previous: EditTransaction, with next: EditTransaction) -> Bool {
        guard previous.isTyping,
              next.isTyping,
              let previousEdit = previous.edits.last,
              let nextEdit = next.edits.first,
              previousEdit.bufferId == nextEdit.bufferId,
              previousEdit.oldRange?.isEmpty == true,
              nextEdit.oldRange?.isEmpty == true,
              !previousEdit.newText.contains("\n"),
              !nextEdit.newText.contains("\n"),
              previous.cursorAfter != nil,
              previous.cursorAfter == next.cursorBefore,
              previous.anchorAfter == nil,
              next.anchorBefore == nil,
              next.timestamp.timeIntervalSince(previous.timestamp) >= 0,
              next.timestamp.timeIntervalSince(previous.timestamp) <= Self.typingCoalescingInterval else {
            return false
        }

        return true
    }

    /// Removes transactions that refer to buffers which are no longer part of
    /// the multibuffer. A transaction is atomic, so it is discarded if any of
    /// its edits targets an invalidated buffer.
    public func invalidate(bufferIds: Set<BufferId>) {
        guard !bufferIds.isEmpty else { return }
        undoStack.removeAll { transaction in
            transaction.edits.contains { bufferIds.contains($0.bufferId) }
        }
        redoStack.removeAll { transaction in
            transaction.edits.contains { bufferIds.contains($0.bufferId) }
        }
        coalescingAllowed = false
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        coalescingAllowed = true
    }
}
