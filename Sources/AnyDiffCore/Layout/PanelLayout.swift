import Foundation
import Combine

/// Available slots in the 3-panel layout.
public enum PanelSlot: String, CaseIterable, Codable, Hashable, Sendable {
    case left
    case center
    case right

    public var title: String {
        switch self {
        case .left: return "Left Panel"
        case .center: return "Center Panel"
        case .right: return "Right Panel"
        }
    }
}

/// Available content types that can be rendered inside a panel.
public enum PanelContent: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case changes
    case files
    case history
    case editor
    case agent
    case terminal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .changes: return "Changes"
        case .files: return "Files"
        case .history: return "History"
        case .editor: return "Editor"
        case .agent: return "Agent"
        case .terminal: return "Terminal"
        }
    }

    public var iconName: String {
        switch self {
        case .changes: return "arrow.triangle.branch"
        case .files: return "folder"
        case .history: return "clock.arrow.circlepath"
        case .editor: return "doc.text"
        case .agent: return "sparkles"
        case .terminal: return "terminal"
        }
    }

    public var description: String {
        switch self {
        case .changes: return "Git modified files & diff status"
        case .files: return "Project file tree & workspace explorer"
        case .history: return "Git commit history & visual graph"
        case .editor: return "Multi-buffer unified & split diff viewer"
        case .agent: return "AI coding sessions & chat"
        case .terminal: return "Integrated interactive shell terminal"
        }
    }

    /// Whether this content type can be opened in multiple panel slots concurrently.
    public var allowsMultipleInstances: Bool {
        switch self {
        case .agent, .terminal:
            return true
        case .editor, .changes, .files, .history:
            return false
        }
    }
}

/// Manages the layout state of the 3 panels (left, center, right), handling content assignment,
/// movement/vacation to prevent duplicates, right panel visibility, and persistence.
@MainActor
public final class PanelLayoutManager: ObservableObject {
    public static let leftSlotKey = "anydiff_panel_slot_left"
    public static let centerSlotKey = "anydiff_panel_slot_center"
    public static let rightSlotKey = "anydiff_panel_slot_right"
    public static let isRightPanelOpenKey = "anydiff_is_right_panel_open"

    @Published public var leftContent: PanelContent?
    @Published public var centerContent: PanelContent?
    @Published public var rightContent: PanelContent?
    @Published public var isRightPanelOpen: Bool {
        didSet {
            userDefaults.set(isRightPanelOpen, forKey: Self.isRightPanelOpenKey)
        }
    }

    private let userDefaults: UserDefaults

    public init(defaults: UserDefaults = .standard, loadPersisted: Bool = true) {
        self.userDefaults = defaults

        if loadPersisted {
            let leftRaw = defaults.object(forKey: Self.leftSlotKey) as? String
            let centerRaw = defaults.object(forKey: Self.centerSlotKey) as? String
            let rightRaw = defaults.object(forKey: Self.rightSlotKey) as? String

            // Default fallback if not yet configured: left = .changes, center = .editor, right = .agent
            if leftRaw == nil && centerRaw == nil && rightRaw == nil {
                self.leftContent = .changes
                self.centerContent = .editor
                self.rightContent = .agent
            } else {
                self.leftContent = leftRaw.flatMap { $0.isEmpty ? nil : PanelContent(rawValue: $0) }
                self.centerContent = centerRaw.flatMap { $0.isEmpty ? nil : PanelContent(rawValue: $0) }
                self.rightContent = rightRaw.flatMap { $0.isEmpty ? nil : PanelContent(rawValue: $0) }
            }
            self.isRightPanelOpen = defaults.object(forKey: Self.isRightPanelOpenKey) as? Bool ?? true
            sanitizeDuplicates()
        } else {
            self.leftContent = .changes
            self.centerContent = .editor
            self.rightContent = .agent
            self.isRightPanelOpen = true
        }
    }

    private func sanitizeDuplicates() {
        var seen = Set<PanelContent>()
        let slots: [PanelSlot] = [.center, .left, .right]
        for slot in slots {
            guard let content = content(for: slot) else { continue }
            if !content.allowsMultipleInstances {
                if seen.contains(content) {
                    switch slot {
                    case .left: leftContent = nil
                    case .center: centerContent = nil
                    case .right: rightContent = nil
                    }
                } else {
                    seen.insert(content)
                }
            }
        }
    }

    /// Returns the content currently assigned to a slot.
    public func content(for slot: PanelSlot) -> PanelContent? {
        switch slot {
        case .left: return leftContent
        case .center: return centerContent
        case .right: return rightContent
        }
    }

    /// Returns which slot currently contains the specified content, if any.
    /// If multiple slots contain this content, returns the primary/first matching slot.
    public func slot(for content: PanelContent) -> PanelSlot? {
        if leftContent == content { return .left }
        if centerContent == content { return .center }
        if rightContent == content { return .right }
        return nil
    }

    /// Returns all slots containing the specified content.
    public func allSlots(for content: PanelContent) -> [PanelSlot] {
        var slots: [PanelSlot] = []
        if leftContent == content { slots.append(.left) }
        if centerContent == content { slots.append(.center) }
        if rightContent == content { slots.append(.right) }
        return slots
    }

    /// Assigns content to the specified slot.
    /// If the content is already present in another slot and does not allow multiple instances,
    /// it is moved (the other slot becomes empty/nil).
    public func assign(_ content: PanelContent, to slot: PanelSlot) {
        // Vacate other slot if already occupied by this content and multiple instances are not allowed
        if !content.allowsMultipleInstances {
            if slot != .left && leftContent == content {
                leftContent = nil
            }
            if slot != .center && centerContent == content {
                centerContent = nil
            }
            if slot != .right && rightContent == content {
                rightContent = nil
            }
        }

        // Assign to target slot
        switch slot {
        case .left: leftContent = content
        case .center: centerContent = content
        case .right: rightContent = content
        }

        persistState()
    }

    /// Clears the specified slot, returning it to the empty panel selection state.
    public func clear(_ slot: PanelSlot) {
        switch slot {
        case .left: leftContent = nil
        case .center: centerContent = nil
        case .right: rightContent = nil
        }
        persistState()
    }

    /// Toggles the visibility of the right panel.
    public func toggleRightPanel() {
        isRightPanelOpen.toggle()
    }

    /// Resets all slots to the default layout (Left: Changes, Center: Editor, Right: Agent).
    public func resetToDefaults() {
        leftContent = .changes
        centerContent = .editor
        rightContent = .agent
        isRightPanelOpen = true
        persistState()
    }

    private func persistState() {
        if let left = leftContent {
            userDefaults.set(left.rawValue, forKey: Self.leftSlotKey)
        } else {
            userDefaults.set("", forKey: Self.leftSlotKey)
        }

        if let center = centerContent {
            userDefaults.set(center.rawValue, forKey: Self.centerSlotKey)
        } else {
            userDefaults.set("", forKey: Self.centerSlotKey)
        }

        if let right = rightContent {
            userDefaults.set(right.rawValue, forKey: Self.rightSlotKey)
        } else {
            userDefaults.set("", forKey: Self.rightSlotKey)
        }
    }
}
