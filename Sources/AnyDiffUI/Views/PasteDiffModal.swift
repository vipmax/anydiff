import SwiftUI
import AnyDiffCore

public struct PasteDiffModal: View {
    public var onLoadDiff: (String) -> Void
    public var onCancel: () -> Void

    @State private var diffText: String = ""

    public init(onLoadDiff: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onLoadDiff = onLoadDiff
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.below.ecg")
                    .foregroundColor(.blue)
                Text("Load Git Diff / MultiBuffer Excerpts")
                    .font(.headline)
                Spacer()
            }

            Text("Paste a unified diff (`git diff`, PR patch) or select a built-in demo diff below:")
                .font(.caption)
                .foregroundColor(.secondary)

            // Preset Diff Buttons
            HStack(spacing: 8) {
                Button("Load Swift MultiBuffer Demo") {
                    diffText = SampleDiffs.swiftMultiBufferDiff
                }
                .buttonStyle(.bordered)

                Button("Load Rust Zed Demo") {
                    diffText = SampleDiffs.rustZedDiff
                }
                .buttonStyle(.bordered)

                Button("Open .diff File...") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = [.text, .plainText]
                    if panel.runModal() == .OK, let url = panel.url, let content = try? String(contentsOf: url) {
                        diffText = content
                    }
                }
                .buttonStyle(.bordered)
            }

            TextEditor(text: $diffText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 240)
                .padding(4)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button("Load Into MultiBuffer") {
                    guard !diffText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    onLoadDiff(diffText)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
