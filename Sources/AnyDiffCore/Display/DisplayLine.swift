import Foundation

public struct ExcerptHeaderInfo: Sendable, Equatable {
    public var excerptIndex: Int
    public var filePath: String
    public var fileStatus: FileDiffStatus
    public var additions: Int
    public var deletions: Int
    public var isCollapsed: Bool

    public init(
        excerptIndex: Int,
        filePath: String,
        fileStatus: FileDiffStatus,
        additions: Int,
        deletions: Int,
        isCollapsed: Bool = false
    ) {
        self.excerptIndex = excerptIndex
        self.filePath = filePath
        self.fileStatus = fileStatus
        self.additions = additions
        self.deletions = deletions
        self.isCollapsed = isCollapsed
    }
}

public enum ExpandDirection: Sendable, Equatable {
    case up
    case down
    case upAndDown
}

public struct ExpandInfo: Sendable, Equatable {
    public var direction: ExpandDirection
    public var excerptIndex: Int

    public init(direction: ExpandDirection, excerptIndex: Int) {
        self.direction = direction
        self.excerptIndex = excerptIndex
    }
}

public struct DisplayCodeLineInfo: Sendable, Equatable {
    public var excerptIndex: Int
    public var multiBufferRow: MultiBufferRow
    public var bufferRow: BufferRow
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    public var diffKind: DiffLineKind
    public var text: String
    public var language: String
    public var wordDiffRanges: [Range<Int>]
    public var expandInfo: ExpandInfo?

    public init(
        excerptIndex: Int,
        multiBufferRow: MultiBufferRow,
        bufferRow: BufferRow,
        oldLineNumber: Int?,
        newLineNumber: Int?,
        diffKind: DiffLineKind,
        text: String,
        language: String,
        wordDiffRanges: [Range<Int>] = [],
        expandInfo: ExpandInfo? = nil
    ) {
        self.excerptIndex = excerptIndex
        self.multiBufferRow = multiBufferRow
        self.bufferRow = bufferRow
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.diffKind = diffKind
        self.text = text
        self.language = language
        self.wordDiffRanges = wordDiffRanges
        self.expandInfo = expandInfo
    }
}

public struct DisplayFoldGapInfo: Sendable, Equatable {
    public var excerptIndex: Int
    public var nextExcerptIndex: Int?
    public var hiddenCount: Int
    public var isTopGap: Bool
    public var isBottomGap: Bool

    public init(excerptIndex: Int, nextExcerptIndex: Int? = nil, hiddenCount: Int, isTopGap: Bool = false, isBottomGap: Bool = false) {
        self.excerptIndex = excerptIndex
        self.nextExcerptIndex = nextExcerptIndex
        self.hiddenCount = hiddenCount
        self.isTopGap = isTopGap
        self.isBottomGap = isBottomGap
    }
}

public struct DisplayCommentInfo: Sendable, Equatable {
    public var comment: ReviewComment
    public var excerptIndex: Int
    public var lineNumber: Int

    public init(comment: ReviewComment, excerptIndex: Int, lineNumber: Int) {
        self.comment = comment
        self.excerptIndex = excerptIndex
        self.lineNumber = lineNumber
    }
}

/// Visual line rendered in the editor canvas
public enum DisplayLine: Sendable, Equatable {
    case excerptHeader(ExcerptHeaderInfo)
    case code(DisplayCodeLineInfo)
    case foldGap(DisplayFoldGapInfo)
    case inlineComment(DisplayCommentInfo)

    public var isCode: Bool {
        if case .code = self { return true }
        return false
    }

    public var multiBufferRow: MultiBufferRow? {
        if case .code(let info) = self { return info.multiBufferRow }
        return nil
    }
}