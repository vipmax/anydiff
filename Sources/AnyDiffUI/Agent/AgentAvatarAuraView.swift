import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

/// Hardware-accelerated multicolored glowing aura displayed around the agent avatar while working.
public final class AgentAvatarAuraView: NSView {
    private let auraContainerLayer = CALayer()
    private let primaryConicLayer = CAGradientLayer()
    private let secondaryConicLayer = CAGradientLayer()
    private let radialMaskLayer = CALayer()

    private var configuredColors: [NSColor] = []
    private var configuredIsDark: Bool?
    private var fadeGeneration: UInt64 = 0
    public private(set) var isAnimating: Bool = false

    private static let sharedRadialMaskImage: CGImage? = makeRadialMaskImage()
    public static let breatheMinScale: CGFloat = 0.90
    public static let breatheMaxScale: CGFloat = 1.03

    public override var isFlipped: Bool { true }

    public static func auraPadding(forAvatarSize size: CGFloat) -> CGFloat {
        max(6, min(9, ceil(size * 0.30)))
    }

    public static func maxAuraOutset(forAvatarSize size: CGFloat) -> CGFloat {
        let pad = auraPadding(forAvatarSize: size)
        let half = size * 0.5
        return max(0, (half + pad) * breatheMaxScale - half)
    }

    public static func frame(around avatarFrame: NSRect) -> NSRect {
        let pad = auraPadding(forAvatarSize: max(avatarFrame.width, avatarFrame.height))
        return avatarFrame.insetBy(dx: -pad, dy: -pad)
    }

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
        layer?.masksToBounds = false
        layer?.opacity = 0.0

        auraContainerLayer.masksToBounds = false
        auraContainerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        radialMaskLayer.contents = Self.sharedRadialMaskImage
        radialMaskLayer.contentsGravity = .resize
        auraContainerLayer.mask = radialMaskLayer

        primaryConicLayer.type = .conic
        primaryConicLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        primaryConicLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        primaryConicLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        secondaryConicLayer.type = .conic
        secondaryConicLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        secondaryConicLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        secondaryConicLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        secondaryConicLayer.opacity = 0.55

        auraContainerLayer.addSublayer(primaryConicLayer)
        auraContainerLayer.addSublayer(secondaryConicLayer)
        layer?.addSublayer(auraContainerLayer)

        configure(colors: Theme.zedDark.agentAuraColors, isDark: true)
        layoutAuraLayers()
    }

    public override func updateTrackingAreas() {
        // Non-interactive visual aura needs no tracking areas inside chat scroll views.
    }

    public override func resetCursorRects() {
        discardCursorRects()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    public override func layout() {
        super.layout()
        layoutAuraLayers()
    }

    private func layoutAuraLayers() {
        let b = bounds
        let center = CGPoint(x: b.midX, y: b.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        auraContainerLayer.bounds = b
        auraContainerLayer.position = center
        radialMaskLayer.frame = CGRect(origin: .zero, size: b.size)
        primaryConicLayer.bounds = CGRect(origin: .zero, size: b.size)
        primaryConicLayer.position = center
        secondaryConicLayer.bounds = CGRect(origin: .zero, size: b.size)
        secondaryConicLayer.position = center
        CATransaction.commit()
    }

    public func configure(colors: [NSColor], isDark: Bool) {
        let normalized = Self.normalizedFourColors(from: colors)
        if configuredIsDark == isDark && Self.colorsMatch(configuredColors, normalized) {
            return
        }
        configuredColors = normalized
        configuredIsDark = isDark

        let c0 = normalized[0].cgColor
        let c1 = normalized[1].cgColor
        let c2 = normalized[2].cgColor
        let c3 = normalized[3].cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        primaryConicLayer.colors = [c0, c1, c2, c3, c0]
        primaryConicLayer.locations = [0.0, 0.25, 0.5, 0.75, 1.0]

        secondaryConicLayer.colors = [c2, c0, c3, c1, c2]
        secondaryConicLayer.locations = [0.0, 0.25, 0.5, 0.75, 1.0]

        if !isAnimating {
            auraContainerLayer.opacity = isDark ? 0.86 : 0.70
        }
        CATransaction.commit()

        if isAnimating {
            applyAuraAnimations(restartOpacity: true)
        }
    }

    public func startAnimating() {
        if isAnimating {
            if window != nil && !isHidden && primaryConicLayer.animation(forKey: "auraRotateCW") == nil {
                applyAuraAnimations(restartOpacity: true)
            }
            return
        }

        fadeGeneration &+= 1
        isAnimating = true
        isHidden = false

        applyAuraAnimations(restartOpacity: true)

        CATransaction.begin()
        layer?.removeAnimation(forKey: "auraFade")
        let fromOpacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 0.0
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = fromOpacity
        fadeIn.toValue = 1.0
        fadeIn.duration = 0.24
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.opacity = 1.0
        layer?.add(fadeIn, forKey: "auraFade")
        CATransaction.commit()
    }

    public func stopAnimating(animated: Bool = false) {
        fadeGeneration &+= 1
        let targetGen = fadeGeneration

        if !isAnimating && isHidden {
            return
        }
        isAnimating = false

        if !animated || isHidden || window == nil {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.removeAnimation(forKey: "auraFade")
            layer?.opacity = 0.0
            removeAuraAnimations()
            isHidden = true
            CATransaction.commit()
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.fadeGeneration == targetGen, !self.isAnimating else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.removeAuraAnimations()
            self.isHidden = true
            CATransaction.commit()
        }
        let fromOpacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 1.0
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = fromOpacity
        fadeOut.toValue = 0.0
        fadeOut.duration = 0.32
        fadeOut.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.opacity = 0.0
        layer?.add(fadeOut, forKey: "auraFade")
        CATransaction.commit()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && isAnimating && !isHidden {
            applyAuraAnimations(restartOpacity: true)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.opacity = 1.0
            CATransaction.commit()
        }
    }

    private func applyAuraAnimations(restartOpacity: Bool) {
        if primaryConicLayer.animation(forKey: "auraRotateCW") == nil {
            let rotateCW = CABasicAnimation(keyPath: "transform.rotation.z")
            rotateCW.fromValue = 0.0
            rotateCW.toValue = Double.pi * 2.0
            rotateCW.duration = 3.0
            rotateCW.repeatCount = .infinity
            rotateCW.isRemovedOnCompletion = false
            primaryConicLayer.add(rotateCW, forKey: "auraRotateCW")
        }

        if secondaryConicLayer.animation(forKey: "auraRotateCCW") == nil {
            let rotateCCW = CABasicAnimation(keyPath: "transform.rotation.z")
            rotateCCW.fromValue = 0.0
            rotateCCW.toValue = -Double.pi * 2.0
            rotateCCW.duration = 4.7
            rotateCCW.repeatCount = .infinity
            rotateCCW.isRemovedOnCompletion = false
            secondaryConicLayer.add(rotateCCW, forKey: "auraRotateCCW")
        }

        if auraContainerLayer.animation(forKey: "auraBreatheScale") == nil {
            let breatheScale = CABasicAnimation(keyPath: "transform.scale")
            breatheScale.fromValue = Self.breatheMinScale
            breatheScale.toValue = Self.breatheMaxScale
            breatheScale.duration = 1.75
            breatheScale.autoreverses = true
            breatheScale.repeatCount = .infinity
            breatheScale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breatheScale.isRemovedOnCompletion = false
            auraContainerLayer.add(breatheScale, forKey: "auraBreatheScale")
        }

        if restartOpacity || auraContainerLayer.animation(forKey: "auraBreatheOpacity") == nil {
            let isDark = configuredIsDark ?? true
            let lowOpacity: Float = isDark ? 0.70 : 0.54
            let highOpacity: Float = isDark ? 0.96 : 0.80

            let breatheOpacity = CABasicAnimation(keyPath: "opacity")
            breatheOpacity.fromValue = lowOpacity
            breatheOpacity.toValue = highOpacity
            breatheOpacity.duration = 1.75
            breatheOpacity.autoreverses = true
            breatheOpacity.repeatCount = .infinity
            breatheOpacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breatheOpacity.isRemovedOnCompletion = false
            auraContainerLayer.opacity = highOpacity
            auraContainerLayer.add(breatheOpacity, forKey: "auraBreatheOpacity")
        }
    }

    private func removeAuraAnimations() {
        primaryConicLayer.removeAnimation(forKey: "auraRotateCW")
        secondaryConicLayer.removeAnimation(forKey: "auraRotateCCW")
        auraContainerLayer.removeAnimation(forKey: "auraBreatheScale")
        auraContainerLayer.removeAnimation(forKey: "auraBreatheOpacity")
        auraContainerLayer.transform = CATransform3DIdentity
    }

    private static func normalizedFourColors(from colors: [NSColor]) -> [NSColor] {
        let converted = colors.compactMap { $0.usingColorSpace(.sRGB) }
        guard !converted.isEmpty else {
            return [
                NSColor.systemBlue.usingColorSpace(.sRGB) ?? .systemBlue,
                NSColor.systemPurple.usingColorSpace(.sRGB) ?? .systemPurple,
                NSColor.systemPink.usingColorSpace(.sRGB) ?? .systemPink,
                NSColor.systemTeal.usingColorSpace(.sRGB) ?? .systemTeal
            ]
        }
        return (0..<4).map { converted[$0 % converted.count] }
    }

    private static func colorsMatch(_ lhs: [NSColor], _ rhs: [NSColor]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if abs(a.redComponent - b.redComponent) > 0.002 ||
                abs(a.greenComponent - b.greenComponent) > 0.002 ||
                abs(a.blueComponent - b.blueComponent) > 0.002 ||
                abs(a.alphaComponent - b.alphaComponent) > 0.002 {
                return false
            }
        }
        return true
    }

    private static func makeRadialMaskImage() -> CGImage? {
        let size = 128
        let half = CGFloat(size) * 0.5
        let peakRadius: CGFloat = 0.56
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        for y in 0..<size {
            let ny = (CGFloat(y) + 0.5) / half - 1.0
            for x in 0..<size {
                let nx = (CGFloat(x) + 0.5) / half - 1.0
                let r = sqrt(nx * nx + ny * ny)
                let alpha: CGFloat
                if r >= 1.0 {
                    alpha = 0.0
                } else if r < peakRadius {
                    let t = r / peakRadius
                    alpha = 0.06 + 0.94 * pow(t, 2.5)
                } else {
                    let u = (r - peakRadius) / (1.0 - peakRadius)
                    alpha = pow(cos(u * .pi * 0.5), 2.2)
                }
                let byte = UInt8((max(0.0, min(1.0, alpha)) * 255.0).rounded())
                let offset = (y * size + x) * 4
                pixels[offset] = byte
                pixels[offset + 1] = byte
                pixels[offset + 2] = byte
                pixels[offset + 3] = byte
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeMutableBytes { rawBuffer -> CGImage? in
            guard let baseAddress = rawBuffer.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: size,
                      height: size,
                      bitsPerComponent: 8,
                      bytesPerRow: size * 4,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return nil
            }
            return ctx.makeImage()
        }
    }
}

/// SwiftUI wrapper around `AgentAvatarAuraView` for consistent working/launching aura rendering.
public struct AgentAvatarAuraRepresentable: NSViewRepresentable {
    public let theme: Theme
    public let isAnimating: Bool

    public init(theme: Theme, isAnimating: Bool) {
        self.theme = theme
        self.isAnimating = isAnimating
    }

    public func makeNSView(context: Context) -> AgentAvatarAuraView {
        let view = AgentAvatarAuraView()
        view.configure(colors: theme.agentAuraColors, isDark: theme.isDark)
        if isAnimating {
            view.startAnimating()
        } else {
            view.isHidden = true
        }
        return view
    }

    public func updateNSView(_ nsView: AgentAvatarAuraView, context: Context) {
        nsView.configure(colors: theme.agentAuraColors, isDark: theme.isDark)
        if isAnimating {
            nsView.startAnimating()
        } else {
            nsView.stopAnimating(animated: true)
        }
    }
}
