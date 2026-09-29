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
        observers.append(contentsOf: [subviewsObs, resizeObs])
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
        window.backgroundColor = theme.background
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        updateSplitViewDividers(in: window, color: theme.panelDivider)
    }
}

public func updateSplitViewDividers(in window: NSWindow, color: NSColor = NSColor.separatorColor) {
    let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2.0
    let thickness: CGFloat = 1.0 / scale
    func isSplitDivider(_ v: NSView) -> Bool {
        let name = String(describing: type(of: v))
        return name.contains("SplitDivider") || (v.superview is NSSplitView && name.contains("Divider"))
    }
    func rec(v: NSView) {
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
        }
        for s in v.subviews { rec(v: s) }
    }
    if let root = window.contentView?.superview ?? window.contentView {
        rec(v: root)
    }
}
