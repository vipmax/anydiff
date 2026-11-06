import SwiftUI
import AppKit
import AnyDiffCore

final class SystemAppearanceObserver: ObservableObject {
    @Published private(set) var isDark: Bool
    private var appearanceObservation: NSKeyValueObservation?

    init() {
        self.isDark = Self.readIsDark()
        self.appearanceObservation = NSApp.observe(\NSApplication.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isDark = Self.readIsDark()
            }
        }
    }

    private static func readIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

public struct WindowAppearanceConfigurator: NSViewRepresentable {
    public var theme: Theme

    public init(theme: Theme) {
        self.theme = theme
    }

    public func makeNSView(context: Context) -> WindowLifecycleView {
        let view = WindowLifecycleView()
        view.theme = theme
        return view
    }

    public func updateNSView(_ nsView: WindowLifecycleView, context: Context) {
        nsView.theme = theme
        nsView.applyAppearance()
    }
}

public final class WindowLifecycleView: NSView {
    public var theme: Theme = .vesper

    private var observers: [NSObjectProtocol] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupNotificationObservers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupNotificationObservers()
    }

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func setupNotificationObservers() {
        let center = NotificationCenter.default
        let subviewsObs = center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        let resizeObs = center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        let fsEnterObs = center.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        let fsExitObs = center.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        observers.append(contentsOf: [subviewsObs, resizeObs, fsEnterObs, fsExitObs])
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    public override func layout() {
        super.layout()
        applyAppearance()
    }

    public func applyAppearance() {
        guard let window = self.window else { return }
        let targetAppearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.backgroundColor = theme.background
        window.appearance = targetAppearance
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        configureSplitViewControllerHoldingPriorities(in: window)
        updateSplitViewDividers(in: window, color: theme.panelDivider)
        configureFullScreenToolbars(theme: theme)
    }
}

public func configureFullScreenToolbars(theme: Theme) {
    let targetAppearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    for window in NSApp.windows where !window.isMenuOrPanel {
        let className = String(describing: type(of: window))
        if className.contains("FullScreen") || className.contains("Toolbar") {
            window.backgroundColor = theme.background
            window.appearance = targetAppearance
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            if let root = window.contentView?.superview ?? window.contentView {
                hideAuxiliaryTitlebarBackgrounds(in: root)
            }
        }
    }
}

public func hideAuxiliaryTitlebarBackgrounds(in root: NSView) {
    func rec(v: NSView) {
        let name = String(describing: type(of: v))
        if name.contains("TitlebarBackgroundView") || name.contains("ScrollPocket") {
            v.isHidden = true
        }
        for s in v.subviews { rec(v: s) }
    }
    rec(v: root)
}

public func configureSplitViewControllerHoldingPriorities(in window: NSWindow) {
    func rec(v: NSView) {
        if v is NSScrollView || v is MultiBufferEditorView {
            return
        }
        if let sv = v as? NSSplitView, let svc = sv.delegate as? NSSplitViewController {
            let items = svc.splitViewItems
            let p260 = NSLayoutConstraint.Priority(260)
            let p200 = NSLayoutConstraint.Priority(200)
            if items.count >= 3 {
                // Keep items[0] (left sidebar) untouched so native toggleSidebar collapse works cleanly
                if items[0].holdingPriority != p260 {
                    items[0].holdingPriority = p260
                }
                if items[1].holdingPriority != p200 {
                    items[1].holdingPriority = p200
                }
                if items[1].minimumThickness != 0 {
                    items[1].minimumThickness = 0
                }
                if items[2].holdingPriority != p260 {
                    items[2].holdingPriority = p260
                }
                if items[2].minimumThickness > 50 {
                    items[2].minimumThickness = 50
                }
                items[2].viewController.view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(50), for: .horizontal)
            } else if items.count == 2 {
                if items[0].holdingPriority != p200 {
                    items[0].holdingPriority = p200
                }
                if items[0].minimumThickness != 0 {
                    items[0].minimumThickness = 0
                }
                if items[1].holdingPriority != p260 {
                    items[1].holdingPriority = p260
                }
                if items[1].minimumThickness > 50 {
                    items[1].minimumThickness = 50
                }
                items[1].viewController.view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(50), for: .horizontal)
            }
            return
        }
        for s in v.subviews { rec(v: s) }
    }
    if let root = window.contentView?.superview ?? window.contentView {
        rec(v: root)
    }
}

public func updateSplitViewDividers(in window: NSWindow, color: NSColor = NSColor.separatorColor) {
    let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2.0
    let thickness: CGFloat = 1.0 / scale
    func isSplitDivider(_ v: NSView) -> Bool {
        guard v.superview is NSSplitView else { return false }
        let name = String(describing: type(of: v))
        return name.contains("Divider")
    }
    func rec(v: NSView) {
        if v is NSScrollView || v is MultiBufferEditorView {
            return
        }
        if isSplitDivider(v) {
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
            let layerName = "anydiff.divider"
            let lineLayer = v.layer?.sublayers?.first(where: { $0.name == layerName }) ?? CALayer()
            lineLayer.name = layerName
            let lineWidth = min(v.bounds.width, thickness)
            let lineX = max(0, (v.bounds.width - lineWidth) / 2.0)
            lineLayer.frame = CGRect(x: lineX, y: 0, width: lineWidth, height: v.bounds.height)
            lineLayer.backgroundColor = color.cgColor
            lineLayer.opacity = 1.0
            lineLayer.isHidden = false
            if lineLayer.superlayer == nil {
                v.layer?.addSublayer(lineLayer)
            }
            if let subs = v.layer?.sublayers {
                for sub in subs where sub !== lineLayer {
                    sub.isHidden = true
                }
            }
            return
        }
        for s in v.subviews { rec(v: s) }
    }
    if let root = window.contentView?.superview ?? window.contentView {
        rec(v: root)
    }
}

// MARK: - Window Classification Helpers

extension NSWindow {
    /// Indicates whether this window is a primary document or main window (as opposed to popups, menus, panels, or overlays).
    public var isPrimaryAppWindow: Bool {
        canBecomeMain && !(self is NSPanel) && level == .normal
    }

    /// Indicates whether this window is an auxiliary panel, context menu, or popup.
    public var isMenuOrPanel: Bool {
        self is NSPanel || level == .popUpMenu
    }
}

extension NSApplication {
    /// Returns all primary application windows, excluding auxiliary panels, context menus, and overlays.
    public var primaryWindows: [NSWindow] {
        windows.filter(\.isPrimaryAppWindow)
    }
}

