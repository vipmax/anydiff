import SwiftUI
import AnyDiffCore

public struct StatusBarView: View {
    public var currentCursorLocation: ExcerptLocation?
    public var currentCursorPoint: MultiBufferPoint
    public var totalFiles: Int
    public var totalAdditions: Int
    public var totalDeletions: Int
    public var totalComments: Int
    public var theme: Theme

    public init(
        currentCursorLocation: ExcerptLocation?,
        currentCursorPoint: MultiBufferPoint,
        totalFiles: Int,
        totalAdditions: Int,
        totalDeletions: Int,
        totalComments: Int,
        theme: Theme
    ) {
        self.currentCursorLocation = currentCursorLocation
        self.currentCursorPoint = currentCursorPoint
        self.totalFiles = totalFiles
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
        self.totalComments = totalComments
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: 16) {
            cursorLocationInfo
            Spacer()
            if totalComments > 0 {
                commentsCountBadge
            }
            statsSummary
            Text("UTF-8")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color(theme.gutterBackground))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(theme.excerptHeaderBorder).opacity(0.4)),
            alignment: .top
        )
    }

    @ViewBuilder
    private var cursorLocationInfo: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.filled.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if let loc = currentCursorLocation {
                Text("MB[\(currentCursorPoint.row):\(currentCursorPoint.column)] → \(loc.filePath):\(loc.fileLineNumber)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            } else {
                Text("MB[\(currentCursorPoint.row):\(currentCursorPoint.column)]")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }

    @ViewBuilder
    private var commentsCountBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 10))
            Text("\(totalComments) comments")
                .font(.system(size: 11))
        }
        .foregroundColor(.blue)
    }

    @ViewBuilder
    private var statsSummary: some View {
        HStack(spacing: 6) {
            Text("\(totalFiles) files")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text("+\(totalAdditions)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(theme.diffAddedGutter))

            Text("-\(totalDeletions)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(theme.diffDeletedGutter))
        }
    }
}
