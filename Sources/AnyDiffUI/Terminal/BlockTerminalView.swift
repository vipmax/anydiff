import SwiftUI
import AppKit
import AnyDiffCore

/// SwiftUI wrapper for the high-performance virtualized CoreText BlockTerminalNSView.
public struct BlockTerminalView: NSViewRepresentable {
    @ObservedObject public var session: BlockTerminalSession
    public var theme: Theme
    public var fontSize: CGFloat
    public var onSwitchToInteractive: (() -> Void)?

    public init(
        session: BlockTerminalSession,
        theme: Theme,
        fontSize: CGFloat = 12,
        onSwitchToInteractive: (() -> Void)? = nil
    ) {
        self.session = session
        self.theme = theme
        self.fontSize = fontSize
        self.onSwitchToInteractive = onSwitchToInteractive
    }

    public func makeNSView(context: Context) -> BlockTerminalNSView {
        let view = BlockTerminalNSView(
            session: session,
            theme: theme,
            fontSize: fontSize,
            onSwitchToInteractive: onSwitchToInteractive
        )
        return view
    }

    public func updateNSView(_ nsView: BlockTerminalNSView, context: Context) {
        if nsView.session !== session {
            nsView.session = session
        }
        if nsView.theme.id != theme.id {
            nsView.theme = theme
        }
        if nsView.fontSize != fontSize {
            nsView.fontSize = fontSize
        }
        nsView.onSwitchToInteractive = onSwitchToInteractive
    }
}
