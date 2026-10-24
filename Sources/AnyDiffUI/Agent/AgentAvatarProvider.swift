import SwiftUI
import AppKit
import Collaboration
import AnyDiffCore

/// Profile/Agent option for selecting which agent to customize in the avatar editor.
public struct AgentProfileOption: Identifiable, Hashable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// Configuration model for an individual agent avatar.
public struct AgentAvatarItemConfig: Codable, Equatable {
    public var useCustom: Bool
    public var zoom: CGFloat
    public var offsetX: CGFloat
    public var offsetY: CGFloat
    public var avatarSize: CGFloat
    public var showCircle: Bool

    public init(
        useCustom: Bool = false,
        zoom: CGFloat = 1.0,
        offsetX: CGFloat = 0,
        offsetY: CGFloat = 0,
        avatarSize: CGFloat = 24,
        showCircle: Bool = false
    ) {
        self.useCustom = useCustom
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.avatarSize = avatarSize
        self.showCircle = showCircle
    }
}

/// Configuration model for custom avatar positioning, zoom, and avatar circle sizes for user and agents.
public struct AvatarSettings: Codable, Equatable {
    public var useCustom: Bool
    public var zoom: CGFloat
    public var offsetX: CGFloat
    public var offsetY: CGFloat
    public var userAvatarSize: CGFloat

    public var useCustomAgent: Bool
    public var agentZoom: CGFloat
    public var agentOffsetX: CGFloat
    public var agentOffsetY: CGFloat
    public var agentAvatarSize: CGFloat
    public var showAgentCircle: Bool

    /// Per-agent/profile configurations keyed by agent identifier (e.g. "antigravity-acp-djvipmax", "claude", "claude-work")
    public var agentConfigs: [String: AgentAvatarItemConfig]

    public init(
        useCustom: Bool = false,
        zoom: CGFloat = 1.0,
        offsetX: CGFloat = 0,
        offsetY: CGFloat = 0,
        userAvatarSize: CGFloat = 24,
        useCustomAgent: Bool = false,
        agentZoom: CGFloat = 1.0,
        agentOffsetX: CGFloat = 0,
        agentOffsetY: CGFloat = 0,
        agentAvatarSize: CGFloat = 24,
        showAgentCircle: Bool = false,
        agentConfigs: [String: AgentAvatarItemConfig] = [:]
    ) {
        self.useCustom = useCustom
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.userAvatarSize = userAvatarSize
        self.useCustomAgent = useCustomAgent
        self.agentZoom = agentZoom
        self.agentOffsetX = agentOffsetX
        self.agentOffsetY = agentOffsetY
        self.agentAvatarSize = agentAvatarSize
        self.showAgentCircle = showAgentCircle
        self.agentConfigs = agentConfigs
    }

    enum CodingKeys: String, CodingKey {
        case useCustom, zoom, offsetX, offsetY, userAvatarSize
        case useCustomAgent, agentZoom, agentOffsetX, agentOffsetY, agentAvatarSize, showAgentCircle
        case agentConfigs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useCustom = try container.decodeIfPresent(Bool.self, forKey: .useCustom) ?? false
        zoom = try container.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? 1.0
        offsetX = try container.decodeIfPresent(CGFloat.self, forKey: .offsetX) ?? 0
        offsetY = try container.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? 0
        userAvatarSize = try container.decodeIfPresent(CGFloat.self, forKey: .userAvatarSize) ?? 24
        useCustomAgent = try container.decodeIfPresent(Bool.self, forKey: .useCustomAgent) ?? false
        agentZoom = try container.decodeIfPresent(CGFloat.self, forKey: .agentZoom) ?? 1.0
        agentOffsetX = try container.decodeIfPresent(CGFloat.self, forKey: .agentOffsetX) ?? 0
        agentOffsetY = try container.decodeIfPresent(CGFloat.self, forKey: .agentOffsetY) ?? 0
        agentAvatarSize = try container.decodeIfPresent(CGFloat.self, forKey: .agentAvatarSize) ?? 24
        showAgentCircle = try container.decodeIfPresent(Bool.self, forKey: .showAgentCircle) ?? false
        agentConfigs = try container.decodeIfPresent([String: AgentAvatarItemConfig].self, forKey: .agentConfigs) ?? [:]
    }

    public func config(for agentId: String?) -> AgentAvatarItemConfig {
        if let id = agentId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            if let specific = agentConfigs[id] {
                return specific
            }
        }
        return AgentAvatarItemConfig(
            useCustom: false,
            zoom: 1.0,
            offsetX: 0,
            offsetY: 0,
            avatarSize: agentAvatarSize,
            showCircle: showAgentCircle
        )
    }
}

public enum AgentAvatarProvider {
    public static let avatarDidChangeNotification = Notification.Name("anyDiffUserAvatarChanged")

    private static var cachedUserAvatar: NSImage?
    private static var hasLoadedUserAvatar = false
    private static var cachedAgentAvatars: [String: NSImage] = [:]

    public static weak var activePopover: NSPopover?

    // MARK: - File Paths

    public static var avatarDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".anydiff/avatar", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static var originalImageURL: URL {
        avatarDirectory.appendingPathComponent("avatar_original.png")
    }

    public static var renderedAvatarURL: URL {
        avatarDirectory.appendingPathComponent("user_avatar.png")
    }

    public static func sanitizedFileKey(_ key: String) -> String {
        let safe = key.lowercased().map { char -> Character in
            if char.isLetter || char.isNumber || char == "-" || char == "_" {
                return char
            }
            return "-"
        }
        let str = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return str.isEmpty ? "default" : str
    }

    public static func agentOriginalImageURL(for agentId: String? = nil) -> URL {
        guard let id = agentId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return avatarDirectory.appendingPathComponent("agent_avatar_original.png")
        }
        let fileKey = sanitizedFileKey(id)
        return avatarDirectory.appendingPathComponent("agent_avatar_original_\(fileKey).png")
    }

    public static func agentRenderedAvatarURL(for agentId: String? = nil) -> URL {
        guard let id = agentId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return avatarDirectory.appendingPathComponent("agent_avatar.png")
        }
        let fileKey = sanitizedFileKey(id)
        return avatarDirectory.appendingPathComponent("agent_avatar_\(fileKey).png")
    }

    public static var settingsURL: URL {
        avatarDirectory.appendingPathComponent("avatar_settings.json")
    }

    // MARK: - Settings & Cache

    public static func loadSettings() -> AvatarSettings {
        if let data = try? Data(contentsOf: settingsURL),
           let settings = try? JSONDecoder().decode(AvatarSettings.self, from: data) {
            return settings
        }
        return AvatarSettings()
    }

    public static func saveSettings(_ settings: AvatarSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL)
        }
    }

    public static func invalidateCache() {
        cachedUserAvatar = nil
        hasLoadedUserAvatar = false
        cachedAgentAvatars.removeAll()
    }

    public static var currentUserAvatarSize: CGFloat {
        loadSettings().userAvatarSize
    }

    public static var currentAgentAvatarSize: CGFloat {
        loadSettings().agentAvatarSize
    }

    public static func currentAgentAvatarSize(for agentId: String? = nil) -> CGFloat {
        loadSettings().config(for: agentId).avatarSize
    }

    public static func shouldShowAgentCircle(for agentId: String? = nil) -> Bool {
        loadSettings().config(for: agentId).showCircle
    }

    public static var rawOriginalImage: NSImage? {
        let settings = loadSettings()
        if settings.useCustom,
           let data = try? Data(contentsOf: originalImageURL),
           let img = NSImage(data: data) {
            return img
        }
        if let identity = CBIdentity(name: NSUserName(), authority: CBIdentityAuthority.default()),
           let identityImage = identity.image {
            return identityImage
        }
        return nil
    }

    public static func rawAgentOriginalImage(for agentId: String? = nil) -> NSImage? {
        let url = agentOriginalImageURL(for: agentId)
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let img = NSImage(data: data) {
            return img
        }
        return nil
    }

    // MARK: - Avatar Retrieval

    /// Returns the circular user avatar image (custom if configured, otherwise macOS identity or fallback).
    public static var userAvatarImage: NSImage {
        if hasLoadedUserAvatar, let cached = cachedUserAvatar {
            return cached
        }

        let settings = loadSettings()
        if settings.useCustom,
           FileManager.default.fileExists(atPath: renderedAvatarURL.path),
           let data = try? Data(contentsOf: renderedAvatarURL),
           let diskImage = NSImage(data: data) {
            cachedUserAvatar = diskImage
            hasLoadedUserAvatar = true
            return diskImage
        }

        let size = NSSize(width: 48, height: 48) // 2x for 24pt display
        let img: NSImage

        if let identity = CBIdentity(name: NSUserName(), authority: CBIdentityAuthority.default()),
           let identityImage = identity.image {
            img = makeCircularImage(from: identityImage, targetSize: size)
        } else {
            img = makeFallbackUserAvatar(targetSize: size)
        }

        cachedUserAvatar = img
        hasLoadedUserAvatar = true
        return img
    }

    /// Returns the custom agent avatar image if configured for the given agent/profile, or nil if standard icon should be used.
    public static func customAgentAvatarImage(for agentId: String? = nil) -> NSImage? {
        guard let id = agentId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        let settings = loadSettings()
        guard let config = settings.agentConfigs[id], config.useCustom else {
            return nil
        }
        if let cached = cachedAgentAvatars[id] {
            return cached
        }
        let rendURL = agentRenderedAvatarURL(for: id)
        if FileManager.default.fileExists(atPath: rendURL.path),
           let data = try? Data(contentsOf: rendURL),
           let diskImage = NSImage(data: data) {
            cachedAgentAvatars[id] = diskImage
            return diskImage
        }
        return nil
    }

    // MARK: - Save & Reset

    public static func saveAllAvatarSettings(
        settings: AvatarSettings,
        userOriginal: NSImage?,
        userRendered: NSImage?,
        agentOriginal: NSImage?,
        agentRendered: NSImage?,
        activeAgentId: String? = nil
    ) {
        saveSettings(settings)

        if let uOrig = userOriginal, let data = ImageAttachmentHelpers.convertToPNGData(image: uOrig) {
            try? data.write(to: originalImageURL)
        }
        if let uRend = userRendered, let data = ImageAttachmentHelpers.convertToPNGData(image: uRend) {
            try? data.write(to: renderedAvatarURL)
        }

        let origURL = agentOriginalImageURL(for: activeAgentId)
        let rendURL = agentRenderedAvatarURL(for: activeAgentId)

        if let aOrig = agentOriginal, let data = ImageAttachmentHelpers.convertToPNGData(image: aOrig) {
            try? data.write(to: origURL)
        }
        if let aRend = agentRendered, let data = ImageAttachmentHelpers.convertToPNGData(image: aRend) {
            try? data.write(to: rendURL)
        }

        invalidateCache()
        NotificationCenter.default.post(name: avatarDidChangeNotification, object: nil)
    }

    public static func resetToSystemAvatar() {
        var settings = loadSettings()
        settings.useCustom = false
        saveSettings(settings)

        try? FileManager.default.removeItem(at: renderedAvatarURL)
        try? FileManager.default.removeItem(at: originalImageURL)

        invalidateCache()
        NotificationCenter.default.post(name: avatarDidChangeNotification, object: nil)
    }

    public static func resetToDefaultAgent(for agentId: String? = nil) {
        var settings = loadSettings()
        if let id = agentId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            settings.agentConfigs[id] = AgentAvatarItemConfig(useCustom: false)
            let fileKey = sanitizedFileKey(id)
            let origURL = avatarDirectory.appendingPathComponent("agent_avatar_original_\(fileKey).png")
            let rendURL = avatarDirectory.appendingPathComponent("agent_avatar_\(fileKey).png")
            try? FileManager.default.removeItem(at: origURL)
            try? FileManager.default.removeItem(at: rendURL)
        } else {
            settings.useCustomAgent = false
            try? FileManager.default.removeItem(at: avatarDirectory.appendingPathComponent("agent_avatar.png"))
            try? FileManager.default.removeItem(at: avatarDirectory.appendingPathComponent("agent_avatar_original.png"))
        }
        saveSettings(settings)

        invalidateCache()
        NotificationCenter.default.post(name: avatarDidChangeNotification, object: nil)
    }

    // MARK: - Discovered Agent Profiles

    public static func discoveredAgentProfiles(selectedId: String? = nil) -> [AgentProfileOption] {
        var options: [AgentProfileOption] = []
        var seenIds = Set<String>()

        // 1. From saved custom presets in UserDefaults
        if let data = UserDefaults.standard.data(forKey: "anydiff_custom_agent_presets"),
           let presets = try? JSONDecoder().decode([AgentPreset].self, from: data) {
            for p in presets {
                if seenIds.insert(p.id).inserted {
                    options.append(AgentProfileOption(id: p.id, displayName: p.displayName))
                }
            }
        }

        // 2. Built-in presets
        let builtins: [(id: String, name: String)] = [
            ("antigravity-acp", "Antigravity"),
            ("claude", "Claude"),
            ("claude-code-acp", "Claude Code"),
            ("gemini", "Gemini"),
            ("codex", "Codex")
        ]
        for b in builtins {
            if seenIds.insert(b.id).inserted {
                options.append(AgentProfileOption(id: b.id, displayName: b.name))
            }
        }

        #if DEBUG
        if seenIds.insert("mock").inserted {
            options.append(AgentProfileOption(id: "mock", displayName: "Mock Agent"))
        }
        #endif

        // 3. Any from saved avatar settings
        let settings = loadSettings()
        for id in settings.agentConfigs.keys {
            if seenIds.insert(id).inserted {
                let name = id.replacingOccurrences(of: "-", with: " ").capitalized
                options.append(AgentProfileOption(id: id, displayName: name))
            }
        }

        // 4. Ensure current selection is present
        if let sel = selectedId?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            if seenIds.insert(sel).inserted {
                let name = sel.replacingOccurrences(of: "-", with: " ").capitalized
                options.insert(AgentProfileOption(id: sel, displayName: name), at: 0)
            }
        }

        return options
    }

    // MARK: - Circular Rendering

    public static func renderCircularAvatar(
        from image: NSImage,
        zoom: CGFloat,
        offset: CGSize,
        viewportDiameter: CGFloat = 160,
        targetSize: CGFloat = 192
    ) -> NSImage {
        let sourceW = image.size.width > 0 ? image.size.width : CGFloat(image.representations.first?.pixelsWide ?? 100)
        let sourceH = image.size.height > 0 ? image.size.height : CGFloat(image.representations.first?.pixelsHigh ?? 100)
        let imgSize = CGSize(width: max(1, sourceW), height: max(1, sourceH))

        let ratio = targetSize / viewportDiameter
        let baseScale = max(viewportDiameter / imgSize.width, viewportDiameter / imgSize.height)
        let zoomedWidth = imgSize.width * baseScale * zoom * ratio
        let zoomedHeight = imgSize.height * baseScale * zoom * ratio
        let scaledOffsetX = offset.width * ratio
        let scaledOffsetY = offset.height * ratio

        let result = NSImage(size: NSSize(width: targetSize, height: targetSize))
        result.lockFocus()

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()

        let clipPath = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: targetSize, height: targetSize))
        clipPath.addClip()

        let destX = (targetSize - zoomedWidth) / 2 + scaledOffsetX
        let destY = (targetSize - zoomedHeight) / 2 - scaledOffsetY
        let destRect = NSRect(x: destX, y: destY, width: zoomedWidth, height: zoomedHeight)

        image.draw(
            in: destRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )

        context?.restoreGState()
        result.unlockFocus()
        return result
    }

    // MARK: - Popover Presentation

    public static func showEditor(
        relativeTo positioningView: NSView,
        preferredEdge: NSRectEdge = .maxX,
        initialTab: AvatarEditorTab = .user,
        agentId: String? = nil
    ) {
        if let current = activePopover, current.isShown {
            current.close()
            activePopover = nil
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = positioningView.effectiveAppearance

        let editorView = AgentAvatarEditorView(
            initialTab: initialTab,
            initialAgentId: agentId,
            onDismiss: { [weak popover] in
                popover?.close()
                if activePopover === popover {
                    activePopover = nil
                }
            }
        )

        let hostingController = NSHostingController(rootView: editorView)
        hostingController.view.setFrameSize(NSSize(width: 320, height: 470))
        popover.contentSize = NSSize(width: 320, height: 470)
        popover.contentViewController = hostingController

        activePopover = popover
        popover.show(relativeTo: positioningView.bounds, of: positioningView, preferredEdge: preferredEdge)
    }

    public static func showEditorFromKeyWindow(initialTab: AvatarEditorTab = .user, agentId: String? = nil) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
              let contentView = window.contentView else { return }
        showEditor(relativeTo: contentView, preferredEdge: .maxY, initialTab: initialTab, agentId: agentId)
    }

    // MARK: - AppKit View & Helpers

    /// Renders a circular user avatar as an AppKit `AgentAvatarImageView`.
    public static func makeUserAvatarView(size: CGFloat = 24, allowsEditing: Bool = true) -> AgentAvatarImageView {
        let iv = AgentAvatarImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        iv.image = userAvatarImage
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerRadius = size / 2
        iv.layer?.masksToBounds = true
        iv.isUserRole = allowsEditing
        if allowsEditing {
            iv.toolTip = "Click or right-click to customize avatar settings"
            iv.onRightClick = { view in
                showEditor(relativeTo: view, initialTab: .user)
            }
            iv.onClick = { view in
                showEditor(relativeTo: view, initialTab: .user)
            }
        }
        return iv
    }

    /// SwiftUI User Avatar view that updates reactively when the avatar or size changes.
    public static func userAvatarSwiftUIView(size: CGFloat? = nil, allowsEditing: Bool = true) -> some View {
        AgentUserAvatarView(size: size, allowsEditing: allowsEditing)
    }

    /// Returns the agent icon image (custom image if set, otherwise brand SVG or SF Symbol).
    public static func agentDisplayImage(
        for iconName: String,
        agentId: String? = nil,
        fallback: String = "sparkles",
        size: CGFloat = 20
    ) -> NSImage {
        if let custom = customAgentAvatarImage(for: agentId) {
            return custom
        }
        return agentIconImage(for: iconName, fallback: fallback, size: size)
    }

    /// Returns the agent icon image (brand SVG or SF Symbol).
    public static func agentIconImage(for iconName: String, fallback: String = "sparkles", size: CGFloat = 20) -> NSImage {
        if let brand = AgentBrandIcons.image(for: iconName) {
            brand.size = NSSize(width: size, height: size)
            return brand
        }
        if let sfImg = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.75, weight: .semibold)
            return sfImg.withSymbolConfiguration(config) ?? sfImg
        }
        if let fallbackImg = NSImage(systemSymbolName: fallback, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.75, weight: .semibold)
            return fallbackImg.withSymbolConfiguration(config) ?? fallbackImg
        }
        return NSImage()
    }

    private static func makeCircularImage(from source: NSImage, targetSize: NSSize) -> NSImage {
        let result = NSImage(size: targetSize)
        result.lockFocus()

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()

        let rect = NSRect(origin: .zero, size: targetSize)
        let path = NSBezierPath(ovalIn: rect)
        path.addClip()

        source.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)

        context?.restoreGState()
        result.unlockFocus()
        return result
    }

    private static func makeFallbackUserAvatar(targetSize: NSSize) -> NSImage {
        let result = NSImage(size: targetSize)
        result.lockFocus()

        let rect = NSRect(origin: .zero, size: targetSize)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.systemGray.withAlphaComponent(0.3).setFill()
        path.fill()

        if let symbol = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: targetSize.width * 0.45, weight: .medium)
            if let configured = symbol.withSymbolConfiguration(config) {
                let iconRect = NSRect(
                    x: (targetSize.width - configured.size.width) / 2,
                    y: (targetSize.height - configured.size.height) / 2,
                    width: configured.size.width,
                    height: configured.size.height
                )
                NSColor.secondaryLabelColor.setFill()
                configured.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 0.9)
            }
        }

        result.unlockFocus()
        return result
    }
}

// MARK: - AgentAvatarImageView

/// AppKit NSImageView with pointing cursor, right-click, left-click, and context menu support for avatar settings.
public final class AgentAvatarImageView: NSImageView {
    public var onRightClick: ((NSView) -> Void)?
    public var onClick: ((NSView) -> Void)?
    public var isUserRole: Bool = false {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: frame.width > 0 ? frame.width : 24, height: frame.height > 0 ? frame.height : 24)
    }

    public override func resetCursorRects() {
        if isUserRole {
            addCursorRect(bounds, cursor: .pointingHand)
        } else {
            super.resetCursorRects()
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if isUserRole, let onRightClick = onRightClick {
            onRightClick(self)
            return
        }
        super.rightMouseDown(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        if isUserRole, let onClick = onClick {
            onClick(self)
            return
        }
        super.mouseDown(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        if isUserRole {
            let menu = NSMenu(title: "Avatar")
            let editItem = NSMenuItem(title: "Customize Avatar Settings...", action: #selector(handleMenuCustomize), keyEquivalent: "")
            editItem.target = self
            menu.addItem(editItem)

            if AgentAvatarProvider.loadSettings().useCustom {
                let resetItem = NSMenuItem(title: "Reset to macOS Avatar", action: #selector(handleMenuReset), keyEquivalent: "")
                resetItem.target = self
                menu.addItem(resetItem)
            }
            return menu
        }
        return super.menu(for: event)
    }

    @objc private func handleMenuCustomize() {
        onRightClick?(self)
    }

    @objc private func handleMenuReset() {
        AgentAvatarProvider.resetToSystemAvatar()
    }
}

// MARK: - SwiftUI User Avatar View

public struct AgentUserAvatarView: View {
    public var size: CGFloat?
    public let allowsEditing: Bool

    @State private var avatarImage: NSImage = AgentAvatarProvider.userAvatarImage
    @State private var currentSize: CGFloat

    public init(size: CGFloat? = nil, allowsEditing: Bool = true) {
        self.size = size
        self.allowsEditing = allowsEditing
        _currentSize = State(initialValue: size ?? AgentAvatarProvider.currentUserAvatarSize)
    }

    public var body: some View {
        let displaySize = size ?? currentSize

        ZStack {
            Image(nsImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: displaySize, height: displaySize)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )

            if allowsEditing {
                AgentAvatarClickableAnchor { anchorView in
                    AgentAvatarProvider.showEditor(relativeTo: anchorView, preferredEdge: .maxY, initialTab: .user)
                }
                .frame(width: displaySize, height: displaySize)
                .clipShape(Circle())
            }
        }
        .frame(width: displaySize, height: displaySize)
        .onReceive(NotificationCenter.default.publisher(for: AgentAvatarProvider.avatarDidChangeNotification)) { _ in
            self.avatarImage = AgentAvatarProvider.userAvatarImage
            if self.size == nil {
                self.currentSize = AgentAvatarProvider.currentUserAvatarSize
            }
        }
        .help(allowsEditing ? "Click or right-click to customize avatar settings" : "")
        .contextMenu {
            if allowsEditing {
                Button("Customize Avatar Settings...") {
                    AgentAvatarProvider.showEditorFromKeyWindow(initialTab: .user)
                }
                if AgentAvatarProvider.loadSettings().useCustom {
                    Button("Reset to macOS Avatar") {
                        AgentAvatarProvider.resetToSystemAvatar()
                    }
                }
            }
        }
    }
}

public struct AgentAvatarClickableAnchor: NSViewRepresentable {
    public var onClick: (NSView) -> Void

    public func makeNSView(context: Context) -> ClickableView {
        let v = ClickableView()
        v.onClick = onClick
        return v
    }

    public func updateNSView(_ nsView: ClickableView, context: Context) {
        nsView.onClick = onClick
    }

    public final class ClickableView: NSView {
        var onClick: ((NSView) -> Void)?

        public override func mouseDown(with event: NSEvent) {
            onClick?(self)
        }

        public override func rightMouseDown(with event: NSEvent) {
            onClick?(self)
        }

        public override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
}
