import AppKit
import SwiftUI
import QuartzCore

public struct AgentZoomableImageViewRepresentable: NSViewRepresentable {
    public var image: NSImage?
    @Binding public var zoomScale: CGFloat
    public var onPrevious: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onClose: (() -> Void)?

    public init(
        image: NSImage?,
        zoomScale: Binding<CGFloat>,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.image = image
        self._zoomScale = zoomScale
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onClose = onClose
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var isInternalGestureUpdate = false
    }

    public func makeNSView(context: Context) -> AgentNativeZoomableImageView {
        let view = AgentNativeZoomableImageView()
        let coordinator = context.coordinator

        view.onZoomScaleChanged = { newScale in
            coordinator.isInternalGestureUpdate = true
            DispatchQueue.main.async {
                self.zoomScale = newScale
            }
        }
        view.onPrevious = onPrevious
        view.onNext = onNext
        view.onClose = onClose
        view.setImage(image, zoomScale: zoomScale)
        return view
    }

    public func updateNSView(_ nsView: AgentNativeZoomableImageView, context: Context) {
        nsView.onPrevious = onPrevious
        nsView.onNext = onNext
        nsView.onClose = onClose

        if context.coordinator.isInternalGestureUpdate {
            // Change originated from user trackpad / mouse gesture inside the NSView itself.
            // Do not call updateImage which would reset or animate zoom towards center.
            context.coordinator.isInternalGestureUpdate = false
            return
        }

        nsView.updateImage(image, externalZoomScale: zoomScale)
    }
}

public final class AgentNativeZoomableImageView: NSView {
    public override var isFlipped: Bool { true }

    public var onZoomScaleChanged: ((CGFloat) -> Void)?
    public var onPrevious: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onClose: (() -> Void)?

    private var currentImage: NSImage?
    private var zoomScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero

    private let imageLayer = CALayer()
    private let shadowLayer = CALayer()

    private var isDragging: Bool = false
    private var dragStartMouseLocation: CGPoint = .zero
    private var dragStartPanOffset: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = .clear

        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.65
        shadowLayer.shadowRadius = 26
        shadowLayer.shadowOffset = CGSize(width: 0, height: 10)
        shadowLayer.masksToBounds = false
        layer?.addSublayer(shadowLayer)

        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.cornerRadius = 12
        imageLayer.borderWidth = 1.0
        imageLayer.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        shadowLayer.addSublayer(imageLayer)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    public override func mouseEntered(with event: NSEvent) {
        updateCursor()
    }

    public override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        if zoomScale > 1.01 {
            if isDragging {
                NSCursor.closedHand.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    public func setImage(_ image: NSImage?, zoomScale: CGFloat) {
        self.currentImage = image
        self.zoomScale = zoomScale
        self.panOffset = .zero
        applyImageToLayer()
        updateLayout(animated: false)
    }

    public func updateImage(_ image: NSImage?, externalZoomScale: CGFloat) {
        let imageChanged = currentImage != image
        self.currentImage = image
        if imageChanged {
            self.zoomScale = externalZoomScale
            self.panOffset = .zero
            applyImageToLayer()
            updateLayout(animated: false)
        } else if abs(self.zoomScale - externalZoomScale) > 0.01 {
            // Programmatic change from UI button (e.g. Toolbar + / - / reset)
            zoom(to: externalZoomScale, centeredAt: nil, animated: true)
        }
    }

    private func applyImageToLayer() {
        guard let img = currentImage else {
            imageLayer.contents = nil
            return
        }
        if let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cgImage
        } else {
            imageLayer.contents = img
        }
    }

    public override func layout() {
        super.layout()
        updateLayout(animated: false)
    }

    private func calculateFitSize() -> CGSize {
        guard let img = currentImage, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let imgSize = img.size
        guard imgSize.width > 0, imgSize.height > 0 else { return .zero }

        let availW = bounds.width
        let availH = bounds.height

        let scaleW = availW / imgSize.width
        let scaleH = availH / imgSize.height
        let fitScale = min(scaleW, scaleH)

        return CGSize(
            width: floor(imgSize.width * fitScale),
            height: floor(imgSize.height * fitScale)
        )
    }

    private func maxPanOffsets(for scale: CGFloat) -> (CGFloat, CGFloat) {
        let fitSize = calculateFitSize()
        let visualW = fitSize.width * scale
        let visualH = fitSize.height * scale

        let maxX = max(0, visualW / 2 + bounds.width / 2 - 40)
        let maxY = max(0, visualH / 2 + bounds.height / 2 - 40)
        return (maxX, maxY)
    }

    private func updateLayout(animated: Bool) {
        let fitSize = calculateFitSize()
        guard fitSize.width > 0, fitSize.height > 0 else { return }

        let visualW = fitSize.width * zoomScale
        let visualH = fitSize.height * zoomScale

        let centerX = bounds.midX + panOffset.x
        let centerY = bounds.midY + panOffset.y

        let targetFrame = CGRect(
            x: floor(centerX - visualW / 2),
            y: floor(centerY - visualH / 2),
            width: ceil(visualW),
            height: ceil(visualH)
        )

        let isZoomed = zoomScale > 1.05
        let cornerRadius: CGFloat = isZoomed ? 0 : 12
        let borderWidth: CGFloat = isZoomed ? 0 : 1.0

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))

            imageLayer.frame = CGRect(origin: .zero, size: targetFrame.size)
            shadowLayer.frame = targetFrame
            imageLayer.cornerRadius = cornerRadius
            imageLayer.borderWidth = borderWidth
            shadowLayer.shadowOpacity = isZoomed ? 0 : 0.65

            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            imageLayer.frame = CGRect(origin: .zero, size: targetFrame.size)
            shadowLayer.frame = targetFrame
            imageLayer.cornerRadius = cornerRadius
            imageLayer.borderWidth = borderWidth
            shadowLayer.shadowOpacity = isZoomed ? 0 : 0.65

            CATransaction.commit()
        }

        updateCursor()
    }

    // MARK: - Zooming Math (Centered precisely at cursor location)

    public func zoom(to targetScale: CGFloat, centeredAt cursorLocationInView: CGPoint?, animated: Bool) {
        let clampedScale = max(0.5, min(5.0, targetScale))
        let oldScale = zoomScale
        guard clampedScale != oldScale || (clampedScale <= 1.01 && panOffset != .zero) else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let anchor = cursorLocationInView ?? center

        let scaleRatio = clampedScale / oldScale
        var newPanX = (anchor.x - center.x) - (anchor.x - center.x - panOffset.x) * scaleRatio
        var newPanY = (anchor.y - center.y) - (anchor.y - center.y - panOffset.y) * scaleRatio

        if clampedScale <= 1.01 && cursorLocationInView == nil {
            newPanX = 0
            newPanY = 0
        } else {
            let (maxX, maxY) = maxPanOffsets(for: clampedScale)
            newPanX = max(-maxX, min(maxX, newPanX))
            newPanY = max(-maxY, min(maxY, newPanY))
        }

        self.zoomScale = clampedScale
        self.panOffset = CGPoint(x: newPanX, y: newPanY)

        updateLayout(animated: animated)
        onZoomScaleChanged?(clampedScale)
    }

    // MARK: - Gestures & Event Handling

    public override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + event.magnification
        let newScale = max(0.5, min(5.0, zoomScale * factor))

        zoom(to: newScale, centeredAt: location, animated: false)

        if event.phase == .ended || event.phase == .cancelled {
            if zoomScale < 1.02 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.zoomScale = 1.0
                    self.panOffset = .zero
                    self.updateLayout(animated: false)
                }
                onZoomScaleChanged?(1.0)
            }
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // 1. Zoom with Cmd or Option key + scroll wheel
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : (event.deltaY * 10.0)
            let factor: CGFloat = 1.0 + (rawDelta * 0.018)
            let newScale = max(0.5, min(5.0, zoomScale * factor))
            zoom(to: newScale, centeredAt: location, animated: false)
            return
        }

        // 2. Pan when zoomed in (2-finger scroll on trackpad or mouse wheel)
        if zoomScale > 1.01 {
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : (event.deltaX * 12.0)
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : (event.deltaY * 12.0)

            let (maxX, maxY) = maxPanOffsets(for: zoomScale)
            let newX = max(-maxX, min(maxX, panOffset.x + dx))
            let newY = max(-maxY, min(maxY, panOffset.y + dy))

            panOffset = CGPoint(x: newX, y: newY)
            updateLayout(animated: false)
            return
        }

        // 3. Swipe left/right when scale is 1.0 to change images
        if zoomScale <= 1.01 && event.phase == .ended {
            if event.scrollingDeltaX < -25 {
                onNext?()
            } else if event.scrollingDeltaX > 25 {
                onPrevious?()
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        dragStartMouseLocation = loc
        dragStartPanOffset = panOffset
        isDragging = true
        updateCursor()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let loc = convert(event.locationInWindow, from: nil)

        if zoomScale > 1.01 {
            let dx = loc.x - dragStartMouseLocation.x
            let dy = loc.y - dragStartMouseLocation.y

            let (maxX, maxY) = maxPanOffsets(for: zoomScale)
            let newX = max(-maxX, min(maxX, dragStartPanOffset.x + dx))
            let newY = max(-maxY, min(maxY, dragStartPanOffset.y + dy))

            panOffset = CGPoint(x: newX, y: newY)
            updateLayout(animated: false)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
        updateCursor()

        if event.clickCount == 2 {
            let loc = convert(event.locationInWindow, from: nil)
            if zoomScale > 1.05 {
                zoom(to: 1.0, centeredAt: nil, animated: true)
            } else {
                zoom(to: 2.5, centeredAt: loc, animated: true)
            }
        }
    }
}
