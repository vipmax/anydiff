import SwiftUI
import AppKit

public struct SearchTextFieldRepresentable: NSViewRepresentable {
    @Binding public var text: String
    public var placeholder: String
    public var font: NSFont
    public var textColor: NSColor
    public var placeholderColor: NSColor?
    public var focusToken: UInt64
    @Binding public var isFocused: Bool
    public var onSubmit: () -> Void
    public var onShiftSubmit: (() -> Void)?
    public var onCancel: (() -> Void)?

    public init(
        text: Binding<String>,
        placeholder: String,
        font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        textColor: NSColor = .textColor,
        placeholderColor: NSColor? = nil,
        focusToken: UInt64 = 0,
        isFocused: Binding<Bool>,
        onSubmit: @escaping () -> Void,
        onShiftSubmit: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.focusToken = focusToken
        self._isFocused = isFocused
        self.onSubmit = onSubmit
        self.onShiftSubmit = onShiftSubmit
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> CustomSearchNSTextField {
        let textField = CustomSearchNSTextField()
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.maximumNumberOfLines = 1
        textField.font = font
        textField.textColor = textColor
        updatePlaceholder(for: textField)
        textField.stringValue = text
        textField.delegate = context.coordinator
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let isFocusedBinding = _isFocused
        textField.onFocusChanged = { focused in
            DispatchQueue.main.async {
                if isFocusedBinding.wrappedValue != focused {
                    isFocusedBinding.wrappedValue = focused
                }
            }
        }

        context.coordinator.textField = textField
        context.coordinator.lastFocusToken = focusToken

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            textField.selectText(nil)
            textField.setFocusedState(true)
        }

        return textField
    }

    public func updateNSView(_ textField: CustomSearchNSTextField, context: Context) {
        context.coordinator.parent = self

        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.font = font
        textField.textColor = textColor
        updatePlaceholder(for: textField)

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textField.window?.makeFirstResponder(textField)
                textField.selectText(nil)
                textField.setFocusedState(true)
            }
        }
    }

    private func updatePlaceholder(for textField: NSTextField) {
        if !placeholder.isEmpty {
            let color = placeholderColor ?? NSColor.placeholderTextColor
            textField.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .foregroundColor: color,
                    .font: font
                ]
            )
        } else {
            textField.placeholderAttributedString = nil
        }
    }

    public class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextFieldRepresentable
        weak var textField: NSTextField?
        var lastFocusToken: UInt64 = 0

        init(_ parent: SearchTextFieldRepresentable) {
            self.parent = parent
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            let newString = tf.stringValue
            if parent.text != newString {
                parent.text = newString
            }
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    if let onShift = parent.onShiftSubmit {
                        onShift()
                    } else {
                        parent.onSubmit()
                    }
                } else {
                    parent.onSubmit()
                }
                // Returning true suppresses AppKit's default insertNewline,
                // which prevents selectText: from ever being called.
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if let onCancel = parent.onCancel {
                    onCancel()
                    return true
                }
            }
            return false
        }
    }
}

public final class CustomSearchNSTextField: NSTextField {
    var onFocusChanged: ((Bool) -> Void)?
    private var isCurrentlyFocused: Bool = false

    public func setFocusedState(_ focused: Bool) {
        guard isCurrentlyFocused != focused else { return }
        isCurrentlyFocused = focused
        onFocusChanged?(focused)
    }

    public override func becomeFirstResponder() -> Bool {
        let success = super.becomeFirstResponder()
        if success {
            setFocusedState(true)
        }
        return success
    }

    public override func selectText(_ sender: Any?) {
        super.selectText(sender)
        setFocusedState(true)
    }

    public override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        setFocusedState(true)
    }

    public override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        setFocusedState(true)
    }

    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        setFocusedState(false)
    }

    public override func resignFirstResponder() -> Bool {
        let success = super.resignFirstResponder()
        if success {
            setFocusedState(false)
        }
        return success
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectionChange(_:)),
                name: NSTextView.didChangeSelectionNotification,
                object: nil
            )
        }
    }

    @objc private func handleSelectionChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView,
              editor === currentEditor() else { return }
        setFocusedState(true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
