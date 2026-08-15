import Foundation

/// Manages undo and redo stacks for MultiBuffer edits
public final class MultiBufferUndoManager: @unchecked Sendable {
    private var undoStack: [EditTransaction] = []
    private var redoStack: [EditTransaction] = []
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
        undoStack.append(transaction)
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public func popUndo() -> EditTransaction? {
        guard let transaction = undoStack.popLast() else { return nil }
        redoStack.append(transaction)
        return transaction
    }

    public func popRedo() -> EditTransaction? {
        guard let transaction = redoStack.popLast() else { return nil }
        undoStack.append(transaction)
        return transaction
    }

    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
