import AppKit
import QuartzCore

/// Smooth hardware-accelerated typing indicator displaying 3 animated bouncing/pulsing dots (...).
public final class AgentTypingIndicatorView: NSView {
    private let dot1 = CALayer()
    private let dot2 = CALayer()
    private let dot3 = CALayer()
    private var dotLayers: [CALayer] { [dot1, dot2, dot3] }

    private var dotColor: NSColor = .secondaryLabelColor
    public private(set) var isAnimating: Bool = false

    public static let defaultWidth: CGFloat = 28
    public static let defaultHeight: CGFloat = 16
    private let dotDiameter: CGFloat = 4.5
    private let dotSpacing: CGFloat = 4.5

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        for dot in dotLayers {
            dot.bounds = CGRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
            dot.cornerRadius = dotDiameter / 2
            dot.backgroundColor = dotColor.cgColor
            dot.opacity = 0.35
            layer?.addSublayer(dot)
        }
        layoutDots()
    }

    public override func layout() {
        super.layout()
        layoutDots()
    }

    private func layoutDots() {
        let centerY = bounds.midY
        let startX: CGFloat = 2

        for (index, dot) in dotLayers.enumerated() {
            let x = startX + CGFloat(index) * (dotDiameter + dotSpacing) + (dotDiameter / 2)
            dot.position = CGPoint(x: x, y: centerY)
        }
    }

    public func configure(color: NSColor) {
        self.dotColor = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dotLayers {
            dot.backgroundColor = color.cgColor
        }
        CATransaction.commit()
    }

    public func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true

        let duration: CFTimeInterval = 1.05
        let baseTime = CACurrentMediaTime()

        for (index, dot) in dotLayers.enumerated() {
            dot.removeAnimation(forKey: "typingWave")

            // Vertical bounce animation
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0, -3.0, 0, 0]
            bounce.keyTimes = [0.0, 0.35, 0.7, 1.0]
            bounce.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear)
            ]

            // Opacity pulse animation
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.30, 0.95, 0.30, 0.30]
            opacity.keyTimes = [0.0, 0.35, 0.7, 1.0]
            opacity.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear)
            ]

            // Subtle scale pulse animation
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.85, 1.15, 0.85, 0.85]
            scale.keyTimes = [0.0, 0.35, 0.7, 1.0]
            scale.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear)
            ]

            let group = CAAnimationGroup()
            group.animations = [bounce, opacity, scale]
            group.duration = duration
            group.repeatCount = .infinity
            group.beginTime = baseTime + (Double(index) * 0.16)
            group.isRemovedOnCompletion = false
            group.fillMode = .both

            dot.add(group, forKey: "typingWave")
        }
    }

    public func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dotLayers {
            dot.removeAnimation(forKey: "typingWave")
            dot.opacity = 0.35
            dot.transform = CATransform3DIdentity
        }
        CATransaction.commit()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && !isHidden && isAnimating {
            // Re-apply animations if view was reattached to window
            stopAnimating()
            startAnimating()
        }
    }
}
