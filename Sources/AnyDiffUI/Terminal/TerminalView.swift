import SwiftUI
import AppKit
import AnyDiffCore

/// SwiftUI representable wrapping TerminalNSView.
public struct TerminalView: NSViewRepresentable {
    @ObservedObject public var session: TerminalSession
    public var theme: Theme
    public var fontSize: CGFloat

    public init(session: TerminalSession, theme: Theme, fontSize: CGFloat = 12) {
        self.session = session
        self.theme = theme
        self.fontSize = fontSize
    }

    public func makeNSView(context: Context) -> TerminalNSView {
        let view = TerminalNSView(session: session, theme: theme)
        view.fontSize = fontSize
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    public func updateNSView(_ nsView: TerminalNSView, context: Context) {
        if nsView.theme.id != theme.id {
            nsView.theme = theme
        }
        if nsView.fontSize != fontSize {
            nsView.fontSize = fontSize
        }
        nsView.updateGridDimensions()
    }
}
