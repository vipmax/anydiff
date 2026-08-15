import SwiftUI
import AnyDiffCore

public struct AddCommentModal: View {
    public var filePath: String
    public var lineNumber: Int
    public var onAdd: (String, String) -> Void
    public var onCancel: () -> Void

    @State private var author: String = "CodeReviewer"
    @State private var content: String = ""

    public init(
        filePath: String,
        lineNumber: Int,
        onAdd: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.onAdd = onAdd
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .foregroundColor(.blue)
                Text("Add Review Comment")
                    .font(.headline)
                Spacer()
                Text("\(filePath):\(lineNumber)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Author")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Your name or handle", text: $author)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Comment")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $content)
                    .font(.system(size: 13))
                    .frame(height: 120)
                    .padding(4)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Add Comment") {
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onAdd(author, content)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
