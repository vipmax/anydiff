import SwiftUI
import AppKit
import AnyDiffCore

public struct OpenRemoteDiffSheetView: View {
    @Binding public var isPresented: Bool
    public var theme: Theme
    public var onOpen: (String) -> Void

    @State private var urlText: String = ""
    @State private var errorMessage: String? = nil
    @State private var isLoading: Bool = false
    @State private var loadingStatus: String = ""

    public struct PresetExample: Identifiable {
        public var id: String { url }
        public let title: String
        public let subtitle: String
        public let url: String
        public let isMega: Bool
    }

    public let presets: [PresetExample] = [
        PresetExample(
            title: "oven-sh/bun #30412",
            subtitle: "Mega-diff: 2,188 files • 1,029,583 lines",
            url: "https://github.com/oven-sh/bun/pull/30412",
            isMega: true
        ),
        PresetExample(
            title: "ghostty-org/ghostty #12291",
            subtitle: "Ghostty terminal feature PR",
            url: "https://github.com/ghostty-org/ghostty/pull/12291",
            isMega: false
        ),
        PresetExample(
            title: "nodejs/node #59805",
            subtitle: "Node.js core PR",
            url: "https://github.com/nodejs/node/pull/59805",
            isMega: false
        )
    ]

    public init(
        isPresented: Binding<Bool>,
        theme: Theme,
        initialURL: String = "",
        onOpen: @escaping (String) -> Void
    ) {
        self._isPresented = isPresented
        self.theme = theme
        self._urlText = State(initialValue: initialURL)
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: "globe")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Open GitHub Diff")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(theme.foreground))
                    Text("View any public PR, commit, compare, or diffshub.com link")
                        .font(.system(size: 12))
                        .foregroundColor(Color(theme.gutterForeground))
                }

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(theme.gutterForeground))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            // Input Form
            VStack(alignment: .leading, spacing: 8) {
                Text("GITHUB OR DIFF URL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 13))
                        .foregroundColor(Color(theme.gutterForeground))

                    TextField("https://github.com/owner/repo/pull/123 or owner/repo#123", text: $urlText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(theme.foreground))
                        .onSubmit {
                            submit()
                        }

                    if !urlText.isEmpty {
                        Button(action: { urlText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(theme.gutterForeground))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(theme.gutterBackground))
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(theme.excerptHeaderBorder), lineWidth: 1)
                )

                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .padding(.top, 2)
                }
            }

            // Quick Presets
            VStack(alignment: .leading, spacing: 8) {
                Text("POPULAR DIFFS & BENCHMARKS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                VStack(spacing: 6) {
                    ForEach(presets) { preset in
                        Button(action: {
                            urlText = preset.url
                            submit()
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: preset.isMega ? "flame.fill" : "arrow.triangle.pull")
                                    .font(.system(size: 12))
                                    .foregroundColor(preset.isMega ? .orange : .accentColor)
                                    .frame(width: 16)

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(preset.title)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(Color(theme.foreground))
                                        if preset.isMega {
                                            Text("1M+ Lines")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.15))
                                                .cornerRadius(3)
                                        }
                                    }
                                    Text(preset.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(theme.gutterForeground))
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(theme.gutterForeground).opacity(0.5))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color(theme.gutterBackground).opacity(0.5))
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Footer Actions
            HStack {
                Button(action: {
                    if let clipboard = NSPasteboard.general.string(forType: .string) {
                        urlText = clipboard
                    }
                }) {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(action: { submit() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                        Text("Open Diff")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(theme.background))
    }

    private func submit() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch GitHubDiffService.shared.parseReference(from: trimmed) {
        case .success:
            errorMessage = nil
            isPresented = false
            onOpen(trimmed)
        case .failure(let err):
            errorMessage = err.localizedDescription
        }
    }
}
