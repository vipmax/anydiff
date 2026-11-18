import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnyDiffCore

public enum AvatarEditorTab: String, CaseIterable, Identifiable {
    case user = "User"
    case agent = "Agent"
    case sizes = "Sizes"

    public var id: String { rawValue }
}

/// Refined avatar settings popover with segmented tabs:
/// - User: custom user avatar with live circle crop, zoom, pan, flip, file selection.
/// - Agent: custom agent avatar with live circle crop, zoom, pan, flip, file selection, per agent & profile.
/// - Sizes: interactive side-by-side preview of user & agent avatars with size sliders & badge toggle.
public struct AgentAvatarEditorView: View {
    public var onDismiss: () -> Void

    @State public var selectedTab: AvatarEditorTab
    public let initialAgentId: String?

    // Agent Options
    @State private var availableAgentOptions: [AgentProfileOption] = []
    @State private var selectedAgentId: String = "antigravity-acp"

    // User Avatar State
    @State private var userSourceImage: NSImage?
    @State private var userZoom: CGFloat = 1.0
    @State private var userOffset: CGSize = .zero
    @State private var userLastDragOffset: CGSize = .zero
    @State private var userFlipHorizontally: Bool = false
    @State private var isUserCustomActive: Bool = false
    @State private var isUserDropTargeted: Bool = false
    @State private var userImageVersion: UUID = UUID()

    // Agent Avatar State (for selectedAgentId)
    @State private var agentSourceImage: NSImage?
    @State private var agentZoom: CGFloat = 1.0
    @State private var agentOffset: CGSize = .zero
    @State private var agentLastDragOffset: CGSize = .zero
    @State private var agentFlipHorizontally: Bool = false
    @State private var isAgentCustomActive: Bool = false
    @State private var isAgentDropTargeted: Bool = false
    @State private var agentImageVersion: UUID = UUID()

    // Sizes State
    @State private var userAvatarSize: CGFloat = 24
    @State private var agentAvatarSize: CGFloat = 24
    @State private var showAgentCircle: Bool = false

    private let circleDiameter: CGFloat = 160

    public init(
        initialTab: AvatarEditorTab = .user,
        initialAgentId: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self._selectedTab = State(initialValue: initialTab)
        self.initialAgentId = initialAgentId
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Segmented Tab Picker: [ User ] [ Agent ] [ Sizes ]
            Picker("", selection: $selectedTab) {
                Text("User Avatar").tag(AvatarEditorTab.user)
                Text("Agent Avatar").tag(AvatarEditorTab.agent)
                Text("Chat Sizes").tag(AvatarEditorTab.sizes)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 2)

            // Content based on selected tab
            switch selectedTab {
            case .user:
                userTabContent
            case .agent:
                agentTabContent
            case .sizes:
                chatSizesTabContent
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Settings") {
                    saveAll()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(
            PopoverEscapeKeyMonitor {
                onDismiss()
            }
        )
        .onAppear {
            loadInitialState()
        }
    }

    // MARK: - Tab 1: User Avatar

    private var userTabContent: some View {
        VStack(spacing: 10) {
            cropViewport(
                image: userSourceImage,
                zoom: userZoom,
                offset: userOffset,
                flipHorizontally: userFlipHorizontally,
                isDropTargeted: isUserDropTargeted,
                emptyLabel: "Drop User Photo Here",
                onZoomChange: { delta in
                    updateUserZoom(to: userZoom + delta)
                },
                onDragChange: { translation in
                    guard let img = userSourceImage else { return }
                    let proposed = CGSize(
                        width: userLastDragOffset.width + translation.width,
                        height: userLastDragOffset.height + translation.height
                    )
                    userOffset = clampOffset(proposed, forZoom: userZoom, image: img)
                },
                onDragEnd: {
                    userLastDragOffset = userOffset
                },
                onDrop: { providers in
                    handleDrop(providers, isAgent: false)
                }
            )
            .id(userImageVersion)

            // Zoom Controls
            HStack(spacing: 8) {
                Button {
                    adjustUserZoom(by: -0.2)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Zoom out")

                Slider(
                    value: Binding(
                        get: { userZoom },
                        set: { updateUserZoom(to: $0) }
                    ),
                    in: 1.0...5.0,
                    step: 0.05
                )
                .controlSize(.small)

                Button {
                    adjustUserZoom(by: 0.2)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Zoom in")

                Text(String(format: "%.0f%%", userZoom * 100))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 4)

            // Action Buttons
            HStack(spacing: 6) {
                Button {
                    pickImage(isAgent: false)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                        Text("Choose Image...")
                    }
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    toggleUserFlip()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: userFlipHorizontally
                              ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                              : "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        Text("Flip")
                    }
                    .lineLimit(1)
                    .foregroundColor(userFlipHorizontally ? .accentColor : .primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(userSourceImage == nil)
                .help("Flip avatar horizontally")

                Spacer(minLength: 4)

                if isUserCustomActive {
                    Button {
                        resetUserToSystem()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to macOS")
                        }
                        .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Tab 2: Agent Avatar

    private var agentTabContent: some View {
        VStack(spacing: 10) {
            // Profile & Agent Selector
            if !availableAgentOptions.isEmpty {
                HStack(spacing: 6) {
                    Text("Agent Profile:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Picker("", selection: $selectedAgentId) {
                        ForEach(availableAgentOptions) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: selectedAgentId) { newId in
                        loadAgentState(for: newId)
                    }
                }
                .padding(.horizontal, 4)
            }

            cropViewport(
                image: agentSourceImage,
                zoom: agentZoom,
                offset: agentOffset,
                flipHorizontally: agentFlipHorizontally,
                isDropTargeted: isAgentDropTargeted,
                emptyLabel: "Drop \(currentAgentDisplayName) Photo",
                onZoomChange: { delta in
                    updateAgentZoom(to: agentZoom + delta)
                },
                onDragChange: { translation in
                    guard let img = agentSourceImage else { return }
                    let proposed = CGSize(
                        width: agentLastDragOffset.width + translation.width,
                        height: agentLastDragOffset.height + translation.height
                    )
                    agentOffset = clampOffset(proposed, forZoom: agentZoom, image: img)
                },
                onDragEnd: {
                    agentLastDragOffset = agentOffset
                },
                onDrop: { providers in
                    handleDrop(providers, isAgent: true)
                }
            )
            .id(agentImageVersion)

            // Zoom Controls
            HStack(spacing: 8) {
                Button {
                    adjustAgentZoom(by: -0.2)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(agentSourceImage == nil)
                .help("Zoom out")

                Slider(
                    value: Binding(
                        get: { agentZoom },
                        set: { updateAgentZoom(to: $0) }
                    ),
                    in: 1.0...5.0,
                    step: 0.05
                )
                .controlSize(.small)
                .disabled(agentSourceImage == nil)

                Button {
                    adjustAgentZoom(by: 0.2)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(agentSourceImage == nil)
                .help("Zoom in")

                Text(String(format: "%.0f%%", agentZoom * 100))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(agentSourceImage != nil ? .secondary : .secondary.opacity(0.4))
                    .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 4)

            // Action Buttons
            HStack(spacing: 6) {
                Button {
                    pickImage(isAgent: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                        Text("Choose Image...")
                    }
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    toggleAgentFlip()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: agentFlipHorizontally
                              ? "arrow.left.and.right.righttriangle.left.righttriangle.right.fill"
                              : "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        Text("Flip")
                    }
                    .lineLimit(1)
                    .foregroundColor(agentFlipHorizontally ? .accentColor : .primary)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(agentSourceImage == nil)
                .help("Flip avatar horizontally")

                Spacer(minLength: 4)

                if isAgentCustomActive {
                    Button {
                        resetAgentToDefault()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to Icon")
                        }
                        .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Tab 3: Chat Sizes

    private var chatSizesTabContent: some View {
        VStack(spacing: 12) {
            // Live Preview Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("LIVE CHAT PREVIEW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.8))

                    Spacer()

                    if !availableAgentOptions.isEmpty {
                        Picker("", selection: $selectedAgentId) {
                            ForEach(availableAgentOptions) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.mini)
                        .onChange(of: selectedAgentId) { newId in
                            loadAgentState(for: newId)
                        }
                    }
                }

                // User Row
                HStack(spacing: 10) {
                    ZStack {
                        Image(nsImage: AgentAvatarProvider.userAvatarImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: userAvatarSize, height: userAvatarSize)
                            .clipShape(Circle())
                    }
                    .frame(width: 50, height: 50, alignment: .center)

                    Text("User message appearance")
                        .font(.system(size: 11.5))
                        .foregroundColor(.primary)
                }
                .frame(height: 50)

                // Agent Row
                HStack(spacing: 10) {
                    ZStack {
                        if let customAgentImg = AgentAvatarProvider.customAgentAvatarImage(for: selectedAgentId), isAgentCustomActive {
                            Image(nsImage: customAgentImg)
                                .resizable()
                                .scaledToFill()
                                .frame(width: agentAvatarSize, height: agentAvatarSize)
                                .clipShape(Circle())
                        } else if isAgentCustomActive, let rawAgent = agentSourceImage {
                            Image(nsImage: rawAgent)
                                .resizable()
                                .scaledToFill()
                                .scaleEffect(x: agentFlipHorizontally ? -1 : 1, y: 1)
                                .frame(width: agentAvatarSize, height: agentAvatarSize)
                                .clipShape(Circle())
                        } else {
                            ZStack {
                                if showAgentCircle {
                                    Circle()
                                        .fill(Color.primary.opacity(0.12))
                                        .frame(width: agentAvatarSize, height: agentAvatarSize)
                                }
                                Image(systemName: "sparkles")
                                    .font(.system(size: showAgentCircle ? max(8, agentAvatarSize * 0.5) : max(10, agentAvatarSize * 0.75)))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: agentAvatarSize, height: agentAvatarSize)
                        }
                    }
                    .frame(width: 50, height: 50, alignment: .center)

                    Text("\(currentAgentDisplayName) response appearance")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(height: 50)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )

            // Sliders Section
            VStack(spacing: 8) {
                HStack {
                    Text("Avatar Size:")
                        .font(.caption)
                        .frame(width: 110, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { userAvatarSize },
                            set: { newValue in
                                userAvatarSize = newValue
                                agentAvatarSize = newValue
                            }
                        ),
                        in: 16...50,
                        step: 2
                    )
                    .controlSize(.small)
                    Text("\(Int(userAvatarSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }

                if !isAgentCustomActive {
                    Toggle(isOn: $showAgentCircle) {
                        Text("Circular background for agent icon")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()
                    let isModified = userAvatarSize != 24 || agentAvatarSize != 24 || showAgentCircle
                    Button("Reset size to default (24 pt)") {
                        userAvatarSize = 24
                        agentAvatarSize = 24
                        showAgentCircle = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(isModified ? 1 : 0)
                    .disabled(!isModified)
                }
                .frame(height: 16)
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Reusable Lens Crop Viewport

    private func cropViewport(
        image: NSImage?,
        zoom: CGFloat,
        offset: CGSize,
        flipHorizontally: Bool = false,
        isDropTargeted: Bool,
        emptyLabel: String,
        onZoomChange: @escaping (CGFloat) -> Void,
        onDragChange: @escaping (CGSize) -> Void,
        onDragEnd: @escaping () -> Void,
        onDrop: @escaping ([NSItemProvider]) -> Bool
    ) -> some View {
        ZStack {
            // Base background
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.4))

            if let img = image {
                let imgSize = normalizedImageSize(img)
                let baseScale = max(circleDiameter / imgSize.width, circleDiameter / imgSize.height)
                let zoomedWidth = imgSize.width * baseScale * zoom
                let zoomedHeight = imgSize.height * baseScale * zoom

                // 1. Surrounding dimmed image context
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: zoomedWidth, height: zoomedHeight)
                    .scaleEffect(x: flipHorizontally ? -1 : 1, y: 1)
                    .offset(x: offset.width, y: offset.height)
                    .frame(width: 200, height: 200)
                    .clipped()
                    .opacity(0.3)

                // 2. Bright circular crop highlight
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: zoomedWidth, height: zoomedHeight)
                    .scaleEffect(x: flipHorizontally ? -1 : 1, y: 1)
                    .offset(x: offset.width, y: offset.height)
                    .frame(width: circleDiameter, height: circleDiameter)
                    .clipShape(Circle())
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary)
                    Text(emptyLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Circular ring border
            Circle()
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.white.opacity(0.85),
                    lineWidth: isDropTargeted ? 2.5 : 1.5
                )
                .frame(width: circleDiameter, height: circleDiameter)
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)

            // Zoom gesture capture
            ZoomGestureView(onZoomDelta: onZoomChange)
                .frame(width: circleDiameter, height: circleDiameter)
        }
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    onDragChange(value.translation)
                }
                .onEnded { _ in
                    onDragEnd()
                }
        )
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: .constant(isDropTargeted), perform: onDrop)
    }

    // MARK: - Logic & Actions

    private var currentAgentDisplayName: String {
        availableAgentOptions.first(where: { $0.id == selectedAgentId })?.displayName ?? "Agent"
    }

    private func normalizedImageSize(_ image: NSImage) -> CGSize {
        let width = image.size.width > 0 ? image.size.width : CGFloat(image.representations.first?.pixelsWide ?? 100)
        let height = image.size.height > 0 ? image.size.height : CGFloat(image.representations.first?.pixelsHigh ?? 100)
        return CGSize(width: width, height: height)
    }

    private func clampOffset(_ proposed: CGSize, forZoom z: CGFloat, image: NSImage) -> CGSize {
        let imgSize = normalizedImageSize(image)
        guard imgSize.width > 0, imgSize.height > 0 else { return .zero }
        let baseScale = max(circleDiameter / imgSize.width, circleDiameter / imgSize.height)
        let zoomedW = imgSize.width * baseScale * z
        let zoomedH = imgSize.height * baseScale * z
        let maxOffsetX = max(0, (zoomedW - circleDiameter) / 2)
        let maxOffsetY = max(0, (zoomedH - circleDiameter) / 2)

        return CGSize(
            width: min(maxOffsetX, max(-maxOffsetX, proposed.width)),
            height: min(maxOffsetY, max(-maxOffsetY, proposed.height))
        )
    }

    private func loadInitialState() {
        let options = AgentAvatarProvider.discoveredAgentProfiles(selectedId: initialAgentId)
        availableAgentOptions = options
        if let initId = initialAgentId, !initId.isEmpty {
            selectedAgentId = initId
        } else if let first = options.first?.id {
            selectedAgentId = first
        }

        let settings = AgentAvatarProvider.loadSettings()
        isUserCustomActive = settings.useCustom
        let unifiedSize = max(settings.userAvatarSize, settings.agentAvatarSize)
        userAvatarSize = unifiedSize
        agentAvatarSize = unifiedSize

        // User image
        if let rawImg = AgentAvatarProvider.rawOriginalImage {
            userSourceImage = rawImg
            userZoom = max(1.0, min(5.0, settings.zoom))
            let clamped = clampOffset(
                CGSize(width: settings.offsetX, height: settings.offsetY),
                forZoom: userZoom,
                image: rawImg
            )
            userOffset = clamped
            userLastDragOffset = clamped
            userFlipHorizontally = settings.useCustom ? settings.flipHorizontally : false
        } else {
            userSourceImage = AgentAvatarProvider.userAvatarImage
            userZoom = 1.0
            userOffset = .zero
            userLastDragOffset = .zero
            userFlipHorizontally = false
        }

        // Load active agent state
        loadAgentState(for: selectedAgentId)
    }

    private func loadAgentState(for agentId: String) {
        let settings = AgentAvatarProvider.loadSettings()
        let config = settings.config(for: agentId)
        isAgentCustomActive = config.useCustom
        agentAvatarSize = userAvatarSize
        showAgentCircle = config.showCircle

        if let rawAgentImg = AgentAvatarProvider.rawAgentOriginalImage(for: agentId) {
            agentSourceImage = rawAgentImg
            agentZoom = max(1.0, min(5.0, config.zoom))
            let clamped = clampOffset(
                CGSize(width: config.offsetX, height: config.offsetY),
                forZoom: agentZoom,
                image: rawAgentImg
            )
            agentOffset = clamped
            agentLastDragOffset = clamped
            agentFlipHorizontally = config.flipHorizontally
        } else if let customAgent = AgentAvatarProvider.customAgentAvatarImage(for: agentId) {
            agentSourceImage = customAgent
            agentZoom = 1.0
            agentOffset = .zero
            agentLastDragOffset = .zero
            agentFlipHorizontally = false
        } else {
            agentSourceImage = nil
            agentZoom = 1.0
            agentOffset = .zero
            agentLastDragOffset = .zero
            agentFlipHorizontally = false
        }
        agentImageVersion = UUID()
    }

    private func updateUserZoom(to newZoom: CGFloat) {
        let clampedZoom = min(5.0, max(1.0, newZoom))
        guard clampedZoom != userZoom else { return }
        if let img = userSourceImage, userZoom > 0 {
            let scale = clampedZoom / userZoom
            let proposed = CGSize(
                width: userOffset.width * scale,
                height: userOffset.height * scale
            )
            userOffset = clampOffset(proposed, forZoom: clampedZoom, image: img)
            userLastDragOffset = userOffset
        }
        userZoom = clampedZoom
    }

    private func updateAgentZoom(to newZoom: CGFloat) {
        let clampedZoom = min(5.0, max(1.0, newZoom))
        guard clampedZoom != agentZoom else { return }
        if let img = agentSourceImage, agentZoom > 0 {
            let scale = clampedZoom / agentZoom
            let proposed = CGSize(
                width: agentOffset.width * scale,
                height: agentOffset.height * scale
            )
            agentOffset = clampOffset(proposed, forZoom: clampedZoom, image: img)
            agentLastDragOffset = agentOffset
        }
        agentZoom = clampedZoom
    }

    private func adjustUserZoom(by delta: CGFloat) {
        updateUserZoom(to: userZoom + delta)
    }

    private func adjustAgentZoom(by delta: CGFloat) {
        updateAgentZoom(to: agentZoom + delta)
    }

    private func toggleUserFlip() {
        guard userSourceImage != nil else { return }
        userFlipHorizontally.toggle()
        userOffset.width = -userOffset.width
        userLastDragOffset.width = userOffset.width
        isUserCustomActive = true
    }

    private func toggleAgentFlip() {
        guard agentSourceImage != nil else { return }
        agentFlipHorizontally.toggle()
        agentOffset.width = -agentOffset.width
        agentLastDragOffset.width = agentOffset.width
        isAgentCustomActive = true
    }

    private func loadNewImage(_ image: NSImage, isAgent: Bool) {
        if isAgent {
            agentSourceImage = image
            agentZoom = 1.0
            agentOffset = .zero
            agentLastDragOffset = .zero
            agentFlipHorizontally = false
            isAgentCustomActive = true
            agentImageVersion = UUID()
        } else {
            userSourceImage = image
            userZoom = 1.0
            userOffset = .zero
            userLastDragOffset = .zero
            userFlipHorizontally = false
            isUserCustomActive = true
            userImageVersion = UUID()
        }
    }

    private func pickImage(isAgent: Bool) {
        let popover = AgentAvatarProvider.activePopover
        let prevBehavior = popover?.behavior ?? .transient
        // Temporarily change behavior so popover doesn't close when open panel becomes active
        popover?.behavior = .applicationDefined

        let panel = NSOpenPanel()
        panel.title = isAgent ? "Select Avatar for \(currentAgentDisplayName)" : "Select User Avatar Image"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .webP, .gif, .tiff]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let response = panel.runModal()

        // Restore popover behavior on next runloop tick
        DispatchQueue.main.async {
            popover?.behavior = prevBehavior
        }

        guard response == .OK, let url = panel.url else { return }

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var loadedImage: NSImage?
        if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
            loadedImage = img
        } else if let img = NSImage(contentsOf: url) {
            loadedImage = img
        }

        guard let image = loadedImage else { return }

        if image.size.width <= 0 || image.size.height <= 0 {
            if let rep = image.representations.first, rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
        }

        DispatchQueue.main.async {
            self.loadNewImage(image, isAgent: isAgent)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], isAgent: Bool) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                var loaded: NSImage?
                if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
                    loaded = img
                } else if let img = NSImage(contentsOf: url) {
                    loaded = img
                }
                if let img = loaded {
                    if img.size.width <= 0 || img.size.height <= 0 {
                        if let rep = img.representations.first, rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                            img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                        }
                    }
                    DispatchQueue.main.async {
                        self.loadNewImage(img, isAgent: isAgent)
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                if let img = img as? NSImage {
                    if img.size.width <= 0 || img.size.height <= 0 {
                        if let rep = img.representations.first, rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                            img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                        }
                    }
                    DispatchQueue.main.async {
                        self.loadNewImage(img, isAgent: isAgent)
                    }
                }
            }
            return true
        }
        return false
    }

    private func resetUserToSystem() {
        AgentAvatarProvider.resetToSystemAvatar()
        isUserCustomActive = false
        userFlipHorizontally = false
        userImageVersion = UUID()
        loadInitialState()
    }

    private func resetAgentToDefault() {
        AgentAvatarProvider.resetToDefaultAgent(for: selectedAgentId)
        isAgentCustomActive = false
        agentSourceImage = nil
        agentFlipHorizontally = false
        agentImageVersion = UUID()
        loadAgentState(for: selectedAgentId)
    }

    private func saveAll() {
        var userRendered: NSImage?
        if let uImg = userSourceImage, isUserCustomActive {
            userRendered = AgentAvatarProvider.renderCircularAvatar(
                from: uImg,
                zoom: userZoom,
                offset: userOffset,
                flipHorizontally: userFlipHorizontally,
                viewportDiameter: circleDiameter,
                targetSize: 192
            )
        }

        var agentRendered: NSImage?
        if let aImg = agentSourceImage, isAgentCustomActive {
            agentRendered = AgentAvatarProvider.renderCircularAvatar(
                from: aImg,
                zoom: agentZoom,
                offset: agentOffset,
                flipHorizontally: agentFlipHorizontally,
                viewportDiameter: circleDiameter,
                targetSize: 192
            )
        }

        var settings = AgentAvatarProvider.loadSettings()
        settings.useCustom = isUserCustomActive
        settings.zoom = userZoom
        settings.offsetX = userOffset.width
        settings.offsetY = userOffset.height
        settings.flipHorizontally = userFlipHorizontally
        settings.userAvatarSize = userAvatarSize
        settings.agentAvatarSize = userAvatarSize
        settings.showAgentCircle = showAgentCircle

        let agentItemConfig = AgentAvatarItemConfig(
            useCustom: isAgentCustomActive,
            zoom: agentZoom,
            offsetX: agentOffset.width,
            offsetY: agentOffset.height,
            flipHorizontally: agentFlipHorizontally,
            avatarSize: userAvatarSize,
            showCircle: showAgentCircle
        )
        settings.agentConfigs[selectedAgentId] = agentItemConfig
        for key in settings.agentConfigs.keys {
            settings.agentConfigs[key]?.avatarSize = userAvatarSize
        }

        AgentAvatarProvider.saveAllAvatarSettings(
            settings: settings,
            userOriginal: isUserCustomActive ? userSourceImage : nil,
            userRendered: userRendered,
            agentOriginal: isAgentCustomActive ? agentSourceImage : nil,
            agentRendered: agentRendered,
            activeAgentId: selectedAgentId
        )

        onDismiss()
    }

    // MARK: - Testable Input Helpers

    static func zoomDelta(
        forScrollingDeltaY scrollingDeltaY: CGFloat,
        hasPreciseDeltas: Bool,
        isMomentum: Bool
    ) -> CGFloat? {
        guard !isMomentum else { return nil }
        let threshold: CGFloat = hasPreciseDeltas ? 0.05 : 0.01
        guard abs(scrollingDeltaY) > threshold else { return nil }
        if hasPreciseDeltas {
            let scaled = scrollingDeltaY * 0.0035
            return min(0.15, max(-0.15, scaled))
        } else {
            let scaled = scrollingDeltaY * 0.05
            return min(0.25, max(-0.25, scaled))
        }
    }

    static func shouldHandleEscapeEvent(
        keyCode: UInt16,
        isARepeat: Bool,
        modifierFlags: NSEvent.ModifierFlags,
        hostWindow: NSWindow?,
        eventWindow: NSWindow?,
        hasModalWindow: Bool,
        isEventTracking: Bool
    ) -> Bool {
        guard keyCode == 53, !isARepeat else { return false }
        guard modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        guard !hasModalWindow, !isEventTracking else { return false }
        guard let hostWindow, hostWindow.isVisible, hostWindow.attachedSheet == nil else { return false }
        if let eventWindow, eventWindow !== hostWindow, eventWindow !== hostWindow.parent {
            return false
        }
        return true
    }
}

// MARK: - Escape Key Monitor NSViewRepresentable

private struct PopoverEscapeKeyMonitor: NSViewRepresentable {
    var onEscape: () -> Void

    func makeNSView(context: Context) -> MonitorNSView {
        let view = MonitorNSView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: MonitorNSView, context: Context) {
        nsView.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: MonitorNSView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class MonitorNSView: NSView {
        var onEscape: (() -> Void)?
        private var keyMonitor: Any?

        deinit {
            removeMonitor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                installMonitorIfNeeded()
                DispatchQueue.main.async { [weak window] in
                    guard let window, window.isVisible, NSApp.modalWindow == nil else { return }
                    window.makeKey()
                }
            } else {
                removeMonitor()
            }
        }

        override func cancelOperation(_ sender: Any?) {
            onEscape?()
        }

        private func installMonitorIfNeeded() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                guard AgentAvatarEditorView.shouldHandleEscapeEvent(
                    keyCode: event.keyCode,
                    isARepeat: event.isARepeat,
                    modifierFlags: event.modifierFlags,
                    hostWindow: self.window,
                    eventWindow: event.window,
                    hasModalWindow: NSApp.modalWindow != nil,
                    isEventTracking: RunLoop.current.currentMode == .eventTracking
                ) else {
                    return event
                }
                self.onEscape?()
                return nil
            }
        }

        func removeMonitor() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }
}

// MARK: - Zoom Gesture NSViewRepresentable

private struct ZoomGestureView: NSViewRepresentable {
    var onZoomDelta: (CGFloat) -> Void

    func makeNSView(context: Context) -> ZoomNSView {
        let view = ZoomNSView()
        view.onZoomDelta = onZoomDelta
        return view
    }

    func updateNSView(_ nsView: ZoomNSView, context: Context) {
        nsView.onZoomDelta = onZoomDelta
    }

    final class ZoomNSView: NSView {
        var onZoomDelta: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            if let delta = AgentAvatarEditorView.zoomDelta(
                forScrollingDeltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                isMomentum: !event.momentumPhase.isEmpty
            ) {
                onZoomDelta?(delta)
            }
        }

        override func magnify(with event: NSEvent) {
            if abs(event.magnification) > 0.005 {
                onZoomDelta?(event.magnification)
            }
        }
    }
}
