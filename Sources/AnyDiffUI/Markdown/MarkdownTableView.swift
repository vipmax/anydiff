import SwiftUI
import AnyDiffCore

public struct MarkdownTableView: View {
    public let headers: [String]
    public let rows: [[String]]
    public let theme: Theme

    public init(headers: [String], rows: [[String]], theme: Theme) {
        self.headers = headers
        self.rows = rows
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                    cellView(header, isHeader: true)
                    if idx < headers.count - 1 {
                        Divider()
                            .overlay(Color(theme.excerptHeaderBorder).opacity(0.35))
                    }
                }
            }
            .background(Color(theme.gutterBackground).opacity(0.75))

            Divider()
                .overlay(Color(theme.excerptHeaderBorder).opacity(0.5))

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(0..<headers.count, id: \.self) { colIdx in
                        let text = colIdx < row.count ? row[colIdx] : ""
                        cellView(text, isHeader: false)
                        if colIdx < headers.count - 1 {
                            Divider()
                                .overlay(Color(theme.excerptHeaderBorder).opacity(0.2))
                        }
                    }
                }
                .background(rowIdx % 2 == 1 ? Color(theme.gutterBackground).opacity(0.25) : Color.clear)

                if rowIdx < rows.count - 1 {
                    Divider()
                        .overlay(Color(theme.excerptHeaderBorder).opacity(0.2))
                }
            }
        }
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(theme.excerptHeaderBorder).opacity(0.35), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cellView(_ text: String, isHeader: Bool) -> some View {
        let attrString = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        Text(attrString)
            .font(isHeader ? .system(size: 12, weight: .bold) : .system(size: 12))
            .foregroundColor(Color(theme.foreground))
            .padding(.horizontal, 12)
            .padding(.vertical, isHeader ? 8 : 7)
            .frame(minWidth: 90, alignment: .leading)
    }
}

