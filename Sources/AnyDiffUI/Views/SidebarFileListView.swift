import SwiftUI
import AnyDiffCore

public struct SidebarFileListView: View {
    public var fileDiffs: [FileDiff]
    @ObservedObject public var reviewManager: ReviewManager
    @Binding public var selectedFilePath: String?
    @State private var searchText: String = ""

    public init(
        fileDiffs: [FileDiff],
        reviewManager: ReviewManager,
        selectedFilePath: Binding<String?>
    ) {
        self.fileDiffs = fileDiffs
        self.reviewManager = reviewManager
        self._selectedFilePath = selectedFilePath
    }

    private var filteredFiles: [FileDiff] {
        if searchText.isEmpty {
            return fileDiffs
        }
        return fileDiffs.filter { $0.displayPath.localizedCaseInsensitiveContains(searchText) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter changed files...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(8)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Header info
            HStack {
                Text("CHANGED FILES (\(filteredFiles.count))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                let totalReviewed = fileDiffs.filter { reviewManager.isFileReviewed(filePath: $0.displayPath) }.count
                Text("\(totalReviewed)/\(fileDiffs.count) reviewed")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Files List
            List(selection: $selectedFilePath) {
                ForEach(filteredFiles) { file in
                    FileRowView(
                        file: file,
                        isReviewed: reviewManager.isFileReviewed(filePath: file.displayPath),
                        onToggleReviewed: {
                            reviewManager.toggleReviewed(filePath: file.displayPath)
                        }
                    )
                    .tag(file.displayPath)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct FileRowView: View {
    let file: FileDiff
    let isReviewed: Bool
    let onToggleReviewed: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Reviewed checkmark
            Button(action: onToggleReviewed) {
                Image(systemName: isReviewed ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isReviewed ? .green : .secondary.opacity(0.6))
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)

            // File Status Badge
            Text(statusSymbol)
                .font(.system(size: 9, weight: .black))
                .foregroundColor(statusColor)
                .frame(width: 14, height: 14)
                .background(statusColor.opacity(0.15))
                .cornerRadius(3)

            // File Path
            Text(file.displayPath)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(isReviewed ? .secondary : .primary)

            Spacer()

            // Diff Stats (+ / -)
            HStack(spacing: 4) {
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                }
                if file.deletions > 0 {
                    Text("-\(file.deletions)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusSymbol: String {
        switch file.status {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .modified: return "M"
        }
    }

    private var statusColor: Color {
        switch file.status {
        case .added: return .green
        case .deleted: return .red
        case .renamed: return .purple
        default: return .blue
        }
    }
}
