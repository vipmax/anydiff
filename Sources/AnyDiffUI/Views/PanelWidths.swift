import SwiftUI
import AnyDiffCore

extension PanelLayoutManager {
    public func minWidth(for slot: PanelSlot) -> CGFloat {
        switch slot {
        case .left:
            switch leftContent {
            case .editor: return 360
            case .agent, .terminal: return 280
            case .history: return 240
            case .changes, .files, nil: return 200
            }
        case .center:
            return 0
        case .right:
            guard isRightPanelOpen else { return 0 }
            return 50
        }
    }

    public func idealWidth(for slot: PanelSlot) -> CGFloat {
        switch slot {
        case .left:
            switch leftContent {
            case .editor: return 500
            case .agent, .terminal: return 360
            case .history: return 320
            case .changes, .files, nil: return 280
            }
        case .center:
            switch centerContent {
            case .changes, .files, .history: return 320
            case .agent, .terminal: return 560
            case .editor, nil: return 760
            }
        case .right:
            guard isRightPanelOpen else { return 0 }
            switch rightContent {
            case .changes, .files, .history: return 320
            case .editor: return 600
            case .agent, .terminal: return 560
            case nil: return 320
            }
        }
    }

    public func maxWidth(for slot: PanelSlot) -> CGFloat {
        switch slot {
        case .left:
            return 1600
        case .center:
            return 1600
        case .right:
            guard isRightPanelOpen else { return 0 }
            return 1600
        }
    }
}
