import SwiftUI
import AppKit
import AnyDiffCore

/// Bottom input bar for the block-based terminal, supporting prompt context, command history, and execution/cancellation.
public struct TerminalInputBarView: View {
    @ObservedObject public var session: BlockTerminalSession
    public var theme: Theme

    @State private var inputText: String = ""
    @State private var historyIndex: Int? = nil
    @State private var temporaryDraft: String = ""
    @State private var isInteractiveHovered: Bool = false
    @State private var isFieldFocused: Bool = false

    public var onSwitchToInteractive: (() -> Void)?

    public init(session: BlockTerminalSession, theme: Theme, onSwitchToInteractive: (() -> Void)? = nil) {
        self.session = session
        self.theme = theme
        self.onSwitchToInteractive = onSwitchToInteractive
    }

    private var shortenedDirectory: String {
        let home = NSHomeDirectory()
        if session.currentDirectory == home {
            return "~"
        } else if session.currentDirectory.hasPrefix(home + "/") {
            return "~/" + session.currentDirectory.dropFirst(home.count + 1)
        } else {
            return session.currentDirectory
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Elevated floating prompt card
            VStack(spacing: 0) {
                contextHeaderRow
                cardDivider
                inputRow
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(theme.inputBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isFieldFocused
                            ? Color(theme.accentColor).opacity(0.65)
                            : Color(theme.excerptHeaderBorder).opacity(0.6),
                        lineWidth: isFieldFocused ? 1.25 : 1.0
                    )
            )
            .shadow(
                color: isFieldFocused ? Color(theme.accentColor).opacity(0.08) : Color.black.opacity(0.06),
                radius: isFieldFocused ? 4 : 2,
                y: 1
            )
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.14), value: isFieldFocused)
        }
        .background(Color(theme.background))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var contextHeaderRow: some View {
        HStack(spacing: 6) {
            // Working directory badge
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 8.5))
                    .foregroundColor(Color(theme.accentColor).opacity(0.85))
                Text(shortenedDirectory)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(theme.foreground).opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(theme.gutterForeground).opacity(0.09))
            )

            // Git branch badge
            if let branch = session.gitBranch {
                HStack(spacing: 3.5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8.5))
                    Text(branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundColor(Color(theme.accentColor))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(theme.accentColor).opacity(0.12))
                )
            }

            // Interactive mode button
            if let onSwitch = onSwitchToInteractive {
                Button(action: onSwitch) {
                    HStack(spacing: 3.5) {
                        Image(systemName: "terminal")
                            .font(.system(size: 8.5))
                        Text("Interactive")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(isInteractiveHovered ? Color(theme.foreground) : Color(theme.gutterForeground))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isInteractiveHovered ? Color(theme.gutterForeground).opacity(0.2) : Color(theme.gutterForeground).opacity(0.09))
                    )
                }
                .buttonStyle(.plain)
                .onHover { isInteractiveHovered = $0 }
                .help("Switch to Native Interactive Terminal")
            }

            Spacer()

            // Running status badge
            if session.isProcessRunning {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text("Running")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.orange)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var cardDivider: some View {
        Rectangle()
            .fill(Color(theme.excerptHeaderBorder).opacity(0.3))
            .frame(height: 1)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(spacing: 7) {
            Text("❯")
                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                .foregroundColor(session.isProcessRunning ? Color.orange : Color(theme.accentColor))
                .padding(.leading, 8)

            TerminalCommandTextField(
                text: $inputText,
                placeholder: session.isProcessRunning ? "Send input to running process..." : "Type a command...",
                history: session.commandHistory,
                isProcessRunning: session.isProcessRunning,
                textColor: theme.foreground,
                placeholderColor: theme.gutterForeground.withAlphaComponent(0.6),
                isFocused: $isFieldFocused,
                onCommit: submitCommand,
                onCancel: {
                    if session.isProcessRunning {
                        session.sendInterrupt()
                    } else {
                        inputText = ""
                    }
                }
            )
            .frame(height: 22)

            if session.isProcessRunning {
                Button(action: { session.sendInterrupt() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7.5))
                        Text("Stop")
                            .font(.system(size: 10, weight: .semibold))
                        Text("⌃C")
                            .font(.system(size: 9, design: .monospaced))
                            .opacity(0.7)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.red.opacity(0.85))
                    )
                }
                .buttonStyle(.plain)
                .help("Send SIGINT (Ctrl+C)")
                .padding(.trailing, 6)
            } else if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: submitCommand) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(theme.accentColor))
                        )
                }
                .buttonStyle(.plain)
                .help("Run Command (Return)")
                .padding(.trailing, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.35))
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 6)
            }
        }
        .padding(.vertical, 4)
    }

    private func submitCommand() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        session.execute(command: trimmed)
    }
}

/// AppKit text field with arrow key history navigation and enter/escape handling.
private struct TerminalCommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var history: [String]
    var isProcessRunning: Bool
    var textColor: NSColor
    var placeholderColor: NSColor
    @Binding var isFocused: Bool
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let tf = KeyCatchingTextField()
        tf.isProcessRunning = isProcessRunning
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.textColor = textColor
        updatePlaceholder(for: tf)
        tf.delegate = context.coordinator
        tf.keyDelegate = context.coordinator
        tf.target = context.coordinator
        tf.action = #selector(Coordinator.actionCommit)
        tf.onFocusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.isFocused = focused
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        updatePlaceholder(for: nsView)
        nsView.textColor = textColor
        if let tf = nsView as? KeyCatchingTextField {
            tf.isProcessRunning = isProcessRunning
            tf.onFocusChanged = { [weak coordinator = context.coordinator] focused in
                coordinator?.parent.isFocused = focused
            }
        }
        context.coordinator.parent = self
    }

    private func updatePlaceholder(for textField: NSTextField) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: placeholderColor
        ]
        textField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: attrs)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, KeyCatchingDelegate {
        var parent: TerminalCommandTextField
        var historyCursor: Int? = nil
        var currentDraft: String = ""

        init(_ parent: TerminalCommandTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
                if historyCursor == nil {
                    currentDraft = tf.stringValue
                }
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused = false
        }

        @objc func actionCommit() {
            parent.onCommit()
            historyCursor = nil
            currentDraft = ""
        }

        func onUpArrow(textField: NSTextField) {
            guard !parent.history.isEmpty else { return }
            if historyCursor == nil {
                currentDraft = textField.stringValue
                historyCursor = parent.history.count - 1
            } else if let cur = historyCursor, cur > 0 {
                historyCursor = cur - 1
            }

            if let idx = historyCursor, idx >= 0 && idx < parent.history.count {
                let val = parent.history[idx]
                textField.stringValue = val
                parent.text = val
            }
        }

        func onDownArrow(textField: NSTextField) {
            guard let cur = historyCursor else { return }
            if cur + 1 < parent.history.count {
                let nextIdx = cur + 1
                historyCursor = nextIdx
                let val = parent.history[nextIdx]
                textField.stringValue = val
                parent.text = val
            } else {
                historyCursor = nil
                textField.stringValue = currentDraft
                parent.text = currentDraft
            }
        }

        func onCancel(textField: NSTextField) {
            parent.onCancel()
        }
    }
}

private protocol KeyCatchingDelegate: AnyObject {
    func onUpArrow(textField: NSTextField)
    func onDownArrow(textField: NSTextField)
    func onCancel(textField: NSTextField)
}

private final class KeyCatchingTextField: NSTextField {
    var isProcessRunning: Bool = false
    var onFocusChanged: ((Bool) -> Void)?
    weak var keyDelegate: KeyCatchingDelegate?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChanged?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            onFocusChanged?(false)
        }
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "c" {
                keyDelegate?.onCancel(textField: self)
                return true
            }
            if !isProcessRunning {
                if event.keyCode == 126 { // Up arrow
                    keyDelegate?.onUpArrow(textField: self)
                    return true
                } else if event.keyCode == 125 { // Down arrow
                    keyDelegate?.onDownArrow(textField: self)
                    return true
                } else if event.keyCode == 53 { // Escape
                    keyDelegate?.onCancel(textField: self)
                    return true
                }
            } else if event.keyCode == 53 { // Escape while running
                keyDelegate?.onCancel(textField: self)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
