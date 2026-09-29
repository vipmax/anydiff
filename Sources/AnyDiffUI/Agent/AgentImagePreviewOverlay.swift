import SwiftUI
import AnyDiffCore

public struct AgentImagePreviewOverlay: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public let theme: Theme

    public init(coordinator: AgentSessionCoordinator, theme: Theme) {
        self.coordinator = coordinator
        self.theme = theme
    }

    public var body: some View {
        if let preview = coordinator.activeImagePreview {
            AgentImagePreviewModalView(
                images: preview.images,
                selectedIndex: Binding(
                    get: { coordinator.activeImagePreview?.selectedIndex },
                    set: { newIdx in
                        if let newIdx = newIdx {
                            coordinator.activeImagePreview?.selectedIndex = newIdx
                        } else {
                            coordinator.activeImagePreview = nil
                        }
                    }
                ),
                allowsEditing: preview.isDraft,
                onDelete: preview.isDraft ? { delIdx in
                    NotificationCenter.default.post(
                        name: Notification.Name("anyDiffDeleteDraftImage"),
                        object: nil,
                        userInfo: ["index": delIdx]
                    )
                    if let currentImages = coordinator.activeImagePreview?.images, delIdx < currentImages.count {
                        var updated = currentImages
                        updated.remove(at: delIdx)
                        if updated.isEmpty {
                            coordinator.activeImagePreview = nil
                        } else {
                            coordinator.activeImagePreview?.images = updated
                        }
                    }
                } : nil,
                onEdit: preview.isDraft ? { index, image in
                    NotificationCenter.default.post(
                        name: Notification.Name("anyDiffUpdateDraftImage"),
                        object: nil,
                        userInfo: ["index": index, "image": image]
                    )
                    if let currentImages = coordinator.activeImagePreview?.images,
                       index >= 0,
                       index < currentImages.count {
                        var updated = currentImages
                        updated[index] = image
                        coordinator.activeImagePreview?.images = updated
                    }
                } : nil,
                theme: theme
            )
            .transition(.opacity)
            .zIndex(999)
        }
    }
}
