import SwiftUI
import AnyDiffCore

extension PanelLayoutManager {
    public func minWidth(for slot: PanelSlot) -> CGFloat {
        switch slot {
        case .left:
            switch leftContent {
            case .editor: return 360
            case .agent: return 280
            case .history: return 240
            case .changes, .files, nil: return 200
            }
        case .center:
            switch centerContent {
            case .changes, .files, .history: return 200
            case .agent: return 280
            case .editor, nil: return 320
            }
        case .right:
            guard isRightPanelOpen else { return 0 }
            switch rightContent {
            case .changes, .files, .history: return 220
            case .editor: return 360
            case .agent: return 320
            case nil: return 240
            }
        }
    }

    public func idealWidth(for slot: PanelSlot) -> CGFloat {
        switch slot {
        case .left:
            switch leftContent {
            case .editor: return 500
            case .agent: return 360
            case .history: return 320
            case .changes, .files, nil: return 280
            }
        case .center:
            switch centerContent {
            case .changes, .files, .history: return 320
            case .agent: return 560
            case .editor, nil: return 760
            }
        case .right:
            guard isRightPanelOpen else { return 0 }
            switch rightContent {
            case .changes, .files, .history: return 320
            case .editor: return 600
            case .agent: return 560
            case nil: return 320
            }
        }
    }

    public func maxWidth(for slot: PanelSlot) -> CGFloat {
        switch slot {
        case .left:
            switch leftContent {
            case .editor: return 1200
            case .agent: return 800
            case .changes, .files, .history, nil: return 800
            }
        case .center:
            return 1600
        case .right:
            guard isRightPanelOpen else { return 0 }
            switch rightContent {
            case .changes, .files, .history: return 800
            case .editor: return 1400
            case .agent: return 950
            case nil: return 800
            }
        }
    }
}
