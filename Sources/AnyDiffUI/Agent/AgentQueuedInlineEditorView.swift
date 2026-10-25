import AppKit
import SwiftUI
import AnyDiffCore

public final class QueuedInlineEditorTextView: NSTextView {
    public var onSave: (() -> Void)?
    public var onCancel: (() -> Void)?
    public var onHeightChanged: (() -> Void)?

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        if event.keyCode == 36 { // Enter
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                onHeightChanged?()
            } else {
                onSave?()
            }
            return
        }
        super.keyDown(with: event)
        onHeightChanged?()
    }

    public override func didChangeText() {
        super.didChangeText()
        onHeightChanged?()
    }
}

public final class AgentQueuedInlineEditorView: NSView {
    public var onSave: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    public var onHeightChange: (() -> Void)?

    public let textView = QueuedInlineEditorTextView()
    private let actionsBar = NSView()
    private let cancelButton = AgentHoverButton()
    private let saveButton = AgentHoverButton()

    private var currentTheme: Theme?
    private var currentAccentColor: Color = .accentColor

    public override var isFlipped: Bool { true }

    public var currentText: String {
        textView.string
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1.5

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        addSubview(textView)

        textView.onSave = { [weak self] in
            self?.handleSave()
        }
        textView.onCancel = { [weak self] in
            self?.handleCancel()
        }
        textView.onHeightChanged = { [weak self] in
            self?.onHeightChange?()
        }

        actionsBar.wantsLayer = true
        addSubview(actionsBar)

        cancelButton.title = "Cancel"
        cancelButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        cancelButton.alignment = .center
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.toolTip = "Cancel (Esc)"
        actionsBar.addSubview(cancelButton)

        saveButton.title = "Save"
        saveButton.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        saveButton.alignment = .center
        saveButton.imagePosition = .imageLeading
        saveButton.imageScaling = .scaleProportionallyDown
        let checkConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        saveButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Save")?.withSymbolConfiguration(checkConfig)
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        saveButton.toolTip = "Save changes (Enter)"
        actionsBar.addSubview(saveButton)
    }

    public func setText(_ text: String, theme: Theme, accentColor: Color) {
        currentTheme = theme
        currentAccentColor = accentColor
        textView.string = text
        updateThemeColors()
    }

    public func updateTheme(theme: Theme, accentColor: Color) {
        currentTheme = theme
        currentAccentColor = accentColor
        updateThemeColors()
    }

    private func updateThemeColors() {
        guard let theme = currentTheme else { return }
        let accentNSColor = NSColor(currentAccentColor)
        let fgColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        let inputBg = NSColor(cgColor: theme.inputBackground.cgColor) ?? (NSColor(cgColor: theme.background.cgColor) ?? .controlBackgroundColor)

        layer?.backgroundColor = inputBg.cgColor
        layer?.borderColor = accentNSColor.withAlphaComponent(0.6).cgColor

        textView.textColor = fgColor
        textView.insertionPointColor = accentNSColor

        let gutterFg = NSColor(cgColor: theme.gutterForeground.cgColor) ?? .secondaryLabelColor

        cancelButton.defaultBackgroundColor = .clear
        cancelButton.hoverBackgroundColor = NSColor.white.withAlphaComponent(0.12)
        cancelButton.contentTintColor = gutterFg
        cancelButton.attributedTitle = NSAttributedString(
            string: "Cancel",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: gutterFg
            ]
        )

        saveButton.defaultBackgroundColor = accentNSColor
        saveButton.hoverBackgroundColor = accentNSColor.withAlphaComponent(0.85)
        saveButton.contentTintColor = .white
        saveButton.attributedTitle = NSAttributedString(
            string: "Save",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
    }

    public func focus() {
        window?.makeFirstResponder(textView)
        let length = textView.string.count
        textView.setSelectedRange(NSRange(location: length, length: 0))
    }

    @objc private func handleSave() {
        let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(trimmed)
    }

    @objc private func handleCancel() {
        onCancel?()
    }

    public func measuredHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(50, width - 16)
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            return 68
        }
        tc.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let textH = ceil(lm.usedRect(for: tc).height)
        let clampedTextH = max(22, textH)
        return 8 + clampedTextH + 8 + 24 + 6
    }

    public func applyLayout(width: CGFloat) {
        let textWidth = max(50, width - 16)
        if let tc = textView.textContainer {
            tc.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let textH = ceil(textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 22)
        let clampedTextH = max(22, textH)

        textView.frame = NSRect(x: 8, y: 8, width: textWidth, height: clampedTextH)

        let actionsY = 8 + clampedTextH + 6
        actionsBar.frame = NSRect(x: 0, y: actionsY, width: width, height: 24)

        let saveW: CGFloat = 64
        let cancelW: CGFloat = 56
        let spacing: CGFloat = 6
        let rightMargin: CGFloat = 8

        let saveX = width - rightMargin - saveW
        let cancelX = saveX - spacing - cancelW

        cancelButton.frame = NSRect(x: cancelX, y: 0, width: cancelW, height: 22)
        saveButton.frame = NSRect(x: saveX, y: 0, width: saveW, height: 22)
    }
}
