import AppKit
import SwiftUI
import QuartzCore
import CoreImage

public enum AgentDrawingTool: Equatable {
    case pencil
    case blur
}

public struct AgentZoomableImageViewRepresentable: NSViewRepresentable {
    public var image: NSImage?
    public var imageID: UUID?
    public var drawingColor: NSColor
    public var drawingTool: AgentDrawingTool
    @Binding public var zoomScale: CGFloat
    @Binding public var isDrawingMode: Bool
    public var undoRequest: Int
    public var copyRequest: Int
    public var onPrevious: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onDrawingStateChanged: ((Bool) -> Void)?
    public var onRenderedImageChanged: ((Data?) -> Void)?

    public init(
        image: NSImage?,
        imageID: UUID? = nil,
        drawingColor: NSColor = .systemRed,
        drawingTool: AgentDrawingTool = .pencil,
        zoomScale: Binding<CGFloat>,
        isDrawingMode: Binding<Bool> = .constant(false),
        undoRequest: Int = 0,
        copyRequest: Int = 0,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        onDrawingStateChanged: ((Bool) -> Void)? = nil,
        onRenderedImageChanged: ((Data?) -> Void)? = nil
    ) {
        self.image = image
        self.imageID = imageID
        self.drawingColor = drawingColor
        self.drawingTool = drawingTool
        self._zoomScale = zoomScale
        self._isDrawingMode = isDrawingMode
        self.undoRequest = undoRequest
        self.copyRequest = copyRequest
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onClose = onClose
        self.onDrawingStateChanged = onDrawingStateChanged
        self.onRenderedImageChanged = onRenderedImageChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public class Coordinator {
        var isInternalGestureUpdate = false
        var lastUndoRequest = 0
        var lastCopyRequest = 0
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
        view.isDrawingMode = isDrawingMode
        view.drawingColor = drawingColor
        view.drawingTool = drawingTool
        view.onDrawingStateChanged = onDrawingStateChanged
        view.onRenderedImageChanged = onRenderedImageChanged
        coordinator.lastUndoRequest = undoRequest
        coordinator.lastCopyRequest = copyRequest
        view.setImage(image, imageID: imageID, zoomScale: zoomScale)
        return view
    }

    public func updateNSView(_ nsView: AgentNativeZoomableImageView, context: Context) {
        nsView.onPrevious = onPrevious
        nsView.onNext = onNext
        nsView.onClose = onClose
        nsView.isDrawingMode = isDrawingMode
        nsView.drawingTool = drawingTool
        nsView.drawingColor = drawingColor
        nsView.onDrawingStateChanged = onDrawingStateChanged
        nsView.onRenderedImageChanged = onRenderedImageChanged

        if context.coordinator.lastUndoRequest != undoRequest {
            context.coordinator.lastUndoRequest = undoRequest
            nsView.undoDrawing()
        }

        if context.coordinator.lastCopyRequest != copyRequest {
            context.coordinator.lastCopyRequest = copyRequest
            nsView.copyImageToPasteboard()
        }

        if context.coordinator.isInternalGestureUpdate {
            // Change originated from user trackpad / mouse gesture inside the NSView itself.
            // Do not call updateImage which would reset or animate zoom towards center.
            context.coordinator.isInternalGestureUpdate = false
            return
        }

        nsView.updateImage(image, imageID: imageID, externalZoomScale: zoomScale)
    }
}

public final class AgentNativeZoomableImageView: NSView {
    public override var isFlipped: Bool { true }

    private struct DrawingStroke {
        let points: [CGPoint]
        let tool: AgentDrawingTool
    }

    public var drawingTool: AgentDrawingTool = .pencil {
        didSet {
            if oldValue != drawingTool {
                activeStroke.removeAll()
                redrawDrawing()
            }
        }
    }

    public var drawingColor: NSColor = .systemRed {
        didSet {
            redrawDrawing()
        }
    }
    public var isDrawingMode: Bool = false {
        didSet {
            guard oldValue != isDrawingMode else { return }
            if !isDrawingMode {
                activeStroke.removeAll()
                redrawDrawing()
            }
            updateCursor()
        }
    }
    public var onZoomScaleChanged: ((CGFloat) -> Void)?
    public var onDrawingStateChanged: ((Bool) -> Void)?
    public var onRenderedImageChanged: ((Data?) -> Void)?
    public var onPrevious: (() -> Void)?
    public var onNext: (() -> Void)?
    public var onClose: (() -> Void)?

    private var currentImage: NSImage?
    private var currentImageID: UUID?
    private var zoomScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero

    private let imageLayer = CALayer()
    private let shadowLayer = CALayer()
    private let drawingLayer = CALayer()
    private let blurLayer = CALayer()
    private let blurMaskLayer = CAShapeLayer()
    private var drawingShapeLayers: [CAShapeLayer] = []
    private var drawingStrokes: [DrawingStroke] = []
    private var activeStroke: [CGPoint] = []
    private var activeDrawingTool: AgentDrawingTool = .pencil

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

        drawingLayer.masksToBounds = true
        blurLayer.masksToBounds = true
        blurLayer.contentsGravity = .resizeAspect
        blurLayer.mask = blurMaskLayer
        blurMaskLayer.fillColor = nil
        blurMaskLayer.strokeColor = NSColor.white.cgColor
        blurMaskLayer.lineCap = .round
        blurMaskLayer.lineJoin = .round
        imageLayer.addSublayer(blurLayer)
        imageLayer.addSublayer(drawingLayer)
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
        if isDrawingMode {
            NSCursor.crosshair.set()
        } else if zoomScale > 1.01 {
            if isDragging {
                NSCursor.closedHand.set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    public func setImage(_ image: NSImage?, imageID: UUID? = nil, zoomScale: CGFloat) {
        self.currentImage = image
        self.currentImageID = imageID
        self.zoomScale = zoomScale
        self.panOffset = .zero
        drawingStrokes.removeAll()
        activeStroke.removeAll()
        applyImageToLayer()
        updateLayout(animated: false)
        onDrawingStateChanged?(false)
        onRenderedImageChanged?(nil)
    }

    public func updateImage(_ image: NSImage?, imageID: UUID? = nil, externalZoomScale: CGFloat) {
        let imageChanged: Bool
        if let imageID {
            imageChanged = currentImageID != imageID
        } else {
            imageChanged = currentImage !== image
        }
        self.currentImage = image
        self.currentImageID = imageID
        if imageChanged {
            self.zoomScale = externalZoomScale
            self.panOffset = .zero
            drawingStrokes.removeAll()
            activeStroke.removeAll()
            applyImageToLayer()
            updateLayout(animated: false)
            onDrawingStateChanged?(false)
            onRenderedImageChanged?(nil)
        } else if abs(self.zoomScale - externalZoomScale) > 0.01 {
            // Programmatic change from UI button (e.g. Toolbar + / - / reset)
            zoom(to: externalZoomScale, centeredAt: nil, animated: true)
        }
    }

    private func applyImageToLayer() {
        guard let img = currentImage else {
            imageLayer.contents = nil
            blurLayer.contents = nil
            return
        }
        if let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cgImage
            blurLayer.contents = blurredCGImage(from: cgImage)
        } else {
            imageLayer.contents = img
            blurLayer.contents = nil
        }
    }

    private func blurredCGImage(from cgImage: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(18.0, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
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

        drawingLayer.frame = imageLayer.bounds
        blurLayer.frame = imageLayer.bounds
        redrawDrawing()
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

    // MARK: - Drawing

    public func undoDrawing() {
        guard !drawingStrokes.isEmpty else { return }
        drawingStrokes.removeLast()
        redrawDrawing()
        onDrawingStateChanged?(!drawingStrokes.isEmpty)
        onRenderedImageChanged?(drawingStrokes.isEmpty ? nil : renderedImageData())
    }

    public func copyImageToPasteboard() {
        guard let image = renderedImage() else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func renderedImageData() -> Data? {
        guard let image = renderedImage(),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func imageFrameInView() -> CGRect {
        let fitSize = calculateFitSize()
        guard fitSize.width > 0, fitSize.height > 0 else { return .zero }

        let visualSize = CGSize(
            width: fitSize.width * zoomScale,
            height: fitSize.height * zoomScale
        )
        let center = CGPoint(
            x: bounds.midX + panOffset.x,
            y: bounds.midY + panOffset.y
        )

        return CGRect(
            x: floor(center.x - visualSize.width / 2),
            y: floor(center.y - visualSize.height / 2),
            width: ceil(visualSize.width),
            height: ceil(visualSize.height)
        )
    }

    private func normalizedImagePoint(from viewPoint: CGPoint, clamped: Bool = false) -> CGPoint? {
        let imageFrame = imageFrameInView()
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        guard clamped || imageFrame.contains(viewPoint) else { return nil }

        let x = (viewPoint.x - imageFrame.minX) / imageFrame.width
        let y = (viewPoint.y - imageFrame.minY) / imageFrame.height
        return CGPoint(
            x: max(0, min(1, x)),
            y: max(0, min(1, y))
        )
    }

    private func redrawDrawing() {
        drawingShapeLayers.forEach { $0.removeFromSuperlayer() }
        drawingShapeLayers.removeAll()

        blurMaskLayer.frame = drawingLayer.bounds
        blurMaskLayer.path = nil

        guard drawingLayer.bounds.width > 0, drawingLayer.bounds.height > 0 else { return }

        let allStrokes = drawingStrokes + (activeStroke.isEmpty ? [] : [
            DrawingStroke(points: activeStroke, tool: activeDrawingTool)
        ])
        let blurPath = CGMutablePath()
        var hasBlurStroke = false

        for stroke in allStrokes where !stroke.points.isEmpty {
            let path = annotationPath(stroke.points, in: drawingLayer.bounds.size, flipY: false)

            switch stroke.tool {
            case .pencil:
                let shapeLayer = CAShapeLayer()
                shapeLayer.frame = drawingLayer.bounds
                shapeLayer.path = path
                shapeLayer.fillColor = nil
                shapeLayer.strokeColor = drawingColor.withAlphaComponent(0.95).cgColor
                shapeLayer.lineWidth = pencilLineWidth(for: drawingLayer.bounds.size)
                shapeLayer.lineCap = .round
                shapeLayer.lineJoin = .round
                drawingLayer.addSublayer(shapeLayer)
                drawingShapeLayers.append(shapeLayer)
            case .blur:
                blurPath.addPath(path)
                hasBlurStroke = true
            }
        }

        if hasBlurStroke {
            blurMaskLayer.path = blurPath
            blurMaskLayer.lineWidth = blurLineWidth(for: drawingLayer.bounds.size)
        }
    }

    private func renderedImage() -> NSImage? {
        guard let currentImage, !drawingStrokes.isEmpty else { return currentImage }
        let size = currentImage.size
        guard size.width > 0, size.height > 0 else { return currentImage }

        let outputImage = NSImage(size: size)
        outputImage.lockFocus()
        currentImage.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        if let context = NSGraphicsContext.current?.cgContext {
            let hasBlurStrokes = drawingStrokes.contains { $0.tool == .blur }
            if hasBlurStrokes,
               let sourceCGImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let blurredCGImage = blurredCGImage(from: sourceCGImage) {
                let blurredImage = NSImage(cgImage: blurredCGImage, size: size)
                for stroke in drawingStrokes where stroke.tool == .blur && !stroke.points.isEmpty {
                    context.saveGState()
                    context.addPath(annotationPath(stroke.points, in: size, flipY: true))
                    context.setLineWidth(blurLineWidth(for: size))
                    context.setLineCap(.round)
                    context.replacePathWithStrokedPath()
                    context.clip()
                    blurredImage.draw(
                        in: NSRect(origin: .zero, size: size),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1
                    )
                    context.restoreGState()
                }
            }

            context.saveGState()
            context.setStrokeColor(drawingColor.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(pencilLineWidth(for: size))
            context.setLineCap(.round)
            context.setLineJoin(.round)

            for stroke in drawingStrokes where stroke.tool == .pencil && !stroke.points.isEmpty {
                context.addPath(annotationPath(stroke.points, in: size, flipY: true))
                context.strokePath()
            }
            context.restoreGState()
        }

        outputImage.unlockFocus()
        return outputImage
    }

    private func annotationPath(_ points: [CGPoint], in size: CGSize, flipY: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }

        func mappedPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: point.x * size.width,
                y: (flipY ? 1 - point.y : point.y) * size.height
            )
        }

        let firstPoint = mappedPoint(first)
        path.move(to: firstPoint)
        if points.count == 1 {
            path.addLine(to: firstPoint)
        } else {
            for point in points.dropFirst() {
                path.addLine(to: mappedPoint(point))
            }
        }
        return path
    }

    private func pencilLineWidth(for size: CGSize) -> CGFloat {
        max(3, min(10, size.width * 0.006))
    }

    private func blurLineWidth(for size: CGSize) -> CGFloat {
        max(28, min(96, min(size.width, size.height) * 0.08))
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

        if isDrawingMode {
            guard let point = normalizedImagePoint(from: loc) else { return }
            activeDrawingTool = drawingTool
            activeStroke = [point]
            redrawDrawing()
            updateCursor()
            return
        }

        dragStartMouseLocation = loc
        dragStartPanOffset = panOffset
        isDragging = true
        updateCursor()
    }

    public override func mouseDragged(with event: NSEvent) {
        if isDrawingMode {
            guard !activeStroke.isEmpty else { return }
            let loc = convert(event.locationInWindow, from: nil)
            guard let point = normalizedImagePoint(from: loc, clamped: true) else { return }
            activeStroke.append(point)
            redrawDrawing()
            return
        }

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
        if isDrawingMode {
            guard !activeStroke.isEmpty else { return }
            if activeStroke.count == 1 {
                activeStroke.append(activeStroke[0])
            }
            drawingStrokes.append(DrawingStroke(points: activeStroke, tool: activeDrawingTool))
            activeStroke.removeAll()
            redrawDrawing()
            onDrawingStateChanged?(true)
            onRenderedImageChanged?(renderedImageData())
            return
        }

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
