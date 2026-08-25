import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentImagePreviewModalView: View {
    public let images: [AgentImageAttachment]
    @Binding public var selectedIndex: Int?
    public var onDelete: ((Int) -> Void)? = nil
    public var theme: Theme

    @State private var zoomScale: CGFloat = 1.0
    @State private var localKeyMonitor: Any? = nil

    public init(
        images: [AgentImageAttachment],
        selectedIndex: Binding<Int?>,
        onDelete: ((Int) -> Void)? = nil,
        theme: Theme
    ) {
        self.images = images
        self._selectedIndex = selectedIndex
        self.onDelete = onDelete
        self.theme = theme
    }

    private var currentIndex: Int {
        guard let idx = selectedIndex, !images.isEmpty else { return 0 }
        return max(0, min(images.count - 1, idx))
    }

    private var currentImage: AgentImageAttachment? {
        guard !images.isEmpty, currentIndex >= 0, currentIndex < images.count else { return nil }
        return images[currentIndex]
    }

    public var body: some View {
        ZStack {
            // Dark blurred backdrop covering the entire window
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture {
                    if zoomScale > 1.05 {
                        resetZoom()
                    } else {
                        close()
                    }
                }

            if let item = currentImage {
                VStack(spacing: 0) {
                    // Top Navigation & Controls Bar
                    topBar(for: item)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                        .zIndex(10)

                    // Main Image Area with Native AppKit Zoom & Pan + Side Chevrons
                    HStack(spacing: 20) {
                        // Previous button
                        if images.count > 1 {
                            Button(action: showPrevious) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white.opacity(currentIndex > 0 ? 0.95 : 0.2))
                                    .frame(width: 48, height: 48)
                                    .background(
                                        Circle()
                                            .fill(Color.white.opacity(currentIndex > 0 ? 0.15 : 0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(currentIndex <= 0)
                            .help("Previous image (Left Arrow)")
                        }

                        Spacer(minLength: 0)

                        // Native Zoomable & Pannable Image Container (centered at cursor)
                        zoomableImageView(for: item)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()

                        Spacer(minLength: 0)

                        // Next button
                        if images.count > 1 {
                            Button(action: showNext) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(.white.opacity(currentIndex < images.count - 1 ? 0.95 : 0.2))
                                    .frame(width: 48, height: 48)
                                    .background(
                                        Circle()
                                            .fill(Color.white.opacity(currentIndex < images.count - 1 ? 0.15 : 0.05))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(currentIndex >= images.count - 1)
                            .help("Next image (Right Arrow)")
                        }
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Bottom Bar: Zoom Controls & Thumbnail Carousel
                    bottomBar
                        .padding(.bottom, 20)
                        .padding(.top, 10)
                        .zIndex(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onChange(of: selectedIndex) { _ in
            resetZoom(animated: false)
        }
    }

    @ViewBuilder
    private func topBar(for item: AgentImageAttachment) -> some View {
        HStack(spacing: 14) {
            // Image Metadata Pill
            HStack(spacing: 8) {
                Text("\(currentIndex + 1) / \(images.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                if let filename = item.filename {
                    Text("·")
                        .foregroundColor(.white.opacity(0.4))
                    Text(filename)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                }

                if let w = item.width, let h = item.height {
                    Text("·")
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(Int(w)) × \(Int(h))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                Text("·")
                    .foregroundColor(.white.opacity(0.4))
                Text(item.fileSizeDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.14))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )

            Spacer()

            // Delete button (if allowed in draft mode)
            if let onDelete = onDelete {
                Button(action: {
                    let deletingIdx = currentIndex
                    if images.count <= 1 {
                        close()
                    } else if deletingIdx >= images.count - 1 {
                        selectedIndex = deletingIdx - 1
                    }
                    onDelete(deletingIdx)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(Color.red.opacity(0.4))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.red.opacity(0.6), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Delete image attachment")
            }

            // Close button
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.95))
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.18))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Close preview (Esc)")
        }
    }

    @ViewBuilder
    private func zoomableImageView(for item: AgentImageAttachment) -> some View {
        if let nsImage = NSImage(data: item.data) {
            AgentZoomableImageViewRepresentable(
                image: nsImage,
                zoomScale: $zoomScale,
                onPrevious: showPrevious,
                onNext: showNext,
                onClose: close
            )
            .id(item.id)
            .transition(.opacity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.6))
                Text("Unable to load image")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Floating Zoom Toolbar
            HStack(spacing: 10) {
                // Zoom Out
                Button(action: zoomOut) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(zoomScale > 0.6 ? 0.9 : 0.3))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(zoomScale <= 0.6)
                .help("Zoom out (Cmd -)")

                // Zoom Level Indicator / Reset button
                Button(action: { resetZoom() }) {
                    Text("\(Int(round(zoomScale * 100)))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(minWidth: 46)
                }
                .buttonStyle(.plain)
                .help("Reset to 100% (Cmd 0)")

                // Zoom In
                Button(action: zoomIn) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(zoomScale < 4.9 ? 0.9 : 0.3))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(zoomScale >= 4.9)
                .help("Zoom in (Cmd +)")

                Divider()
                    .frame(height: 16)
                    .background(Color.white.opacity(0.3))

                // Toggle 100% / 250% Zoom
                Button(action: toggleZoom) {
                    Image(systemName: zoomScale > 1.05 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help(zoomScale > 1.05 ? "Fit to screen" : "Enlarge 2.5x")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.65))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

            // Bottom thumbnail carousel (if multiple images)
            if images.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images.indices, id: \.self) { idx in
                            let item = images[idx]
                            let isSelected = idx == currentIndex

                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedIndex = idx
                                    resetZoom()
                                }
                            }) {
                                if let nsImg = NSImage(data: item.data) {
                                    Image(nsImage: nsImg)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(
                                                    isSelected ? Color.accentColor : Color.white.opacity(0.3),
                                                    lineWidth: isSelected ? 2.5 : 1
                                                )
                                        )
                                        .scaleEffect(isSelected ? 1.08 : 1.0)
                                        .opacity(isSelected ? 1.0 : 0.65)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                .frame(height: 68)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 24)
            }
        }
    }

    private func zoomIn() {
        withAnimation(.easeOut(duration: 0.15)) {
            zoomScale = min(5.0, zoomScale * 1.35)
        }
    }

    private func zoomOut() {
        withAnimation(.easeOut(duration: 0.15)) {
            zoomScale = max(0.5, zoomScale / 1.35)
        }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            if zoomScale > 1.05 {
                resetZoom()
            } else {
                zoomScale = 2.5
            }
        }
    }

    private func resetZoom(animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                zoomScale = 1.0
            }
        } else {
            zoomScale = 1.0
        }
    }

    private func showPrevious() {
        guard currentIndex > 0 else { return }
        resetZoom(animated: false)
        withAnimation(.easeInOut(duration: 0.16)) {
            selectedIndex = currentIndex - 1
        }
    }

    private func showNext() {
        guard currentIndex < images.count - 1 else { return }
        resetZoom(animated: false)
        withAnimation(.easeInOut(duration: 0.16)) {
            selectedIndex = currentIndex + 1
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) {
            selectedIndex = nil
        }
    }

    private func setupKeyboardMonitor() {
        removeKeyboardMonitor()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedIndex != nil else { return event }

            switch event.keyCode {
            case 53: // Escape
                close()
                return nil
            case 123: // Left Arrow
                showPrevious()
                return nil
            case 124: // Right Arrow
                showNext()
                return nil
            case 24, 69: // + or =
                if event.modifierFlags.contains(.command) || !event.modifierFlags.contains(.shift) {
                    zoomIn()
                    return nil
                }
                return event
            case 27, 78: // -
                if event.modifierFlags.contains(.command) || !event.modifierFlags.contains(.shift) {
                    zoomOut()
                    return nil
                }
                return event
            case 29: // 0
                if event.modifierFlags.contains(.command) {
                    resetZoom()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }
}
