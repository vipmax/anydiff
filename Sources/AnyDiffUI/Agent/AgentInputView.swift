import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentAutoGrowingTextView: NSViewRepresentable {
    @Binding public var text: String
    public var placeholder: String
    public var theme: Theme
    public var minHeight: CGFloat = 22
    public var maxHeight: CGFloat = 160
    public var focusRequest: Int = 0
    @Binding public var calculatedHeight: CGFloat
    public var onSend: () -> Void
    public var onFocusChanged: ((Bool) -> Void)?
    public var onImagesPasted: (([AgentImageAttachment]) -> Void)?

    public init(
        text: Binding<String>,
        placeholder: String,
        theme: Theme,
        minHeight: CGFloat = 22,
        maxHeight: CGFloat = 160,
        focusRequest: Int = 0,
        calculatedHeight: Binding<CGFloat>,
        onSend: @escaping () -> Void,
        onFocusChanged: ((Bool) -> Void)? = nil,
        onImagesPasted: (([AgentImageAttachment]) -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.theme = theme
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.focusRequest = focusRequest
        self._calculatedHeight = calculatedHeight
        self.onSend = onSend
        self.onFocusChanged = onFocusChanged
        self.onImagesPasted = onImagesPasted
    }

    public func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.update(from: self, heightBinding: _calculatedHeight)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.registerForDraggedTypes([.fileURL, .png, .tiff])

        let textView = AgentInputCustomTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        textView.insertionPointColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.placeholderString = placeholder
        textView.onSend = onSend
        textView.onFocusChanged = onFocusChanged
        textView.onImagesPasted = onImagesPasted
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.onHeightChanged = { [weak coordinator = context.coordinator] newHeight in
            coordinator?.reportHeight(newHeight)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self, heightBinding: _calculatedHeight)

        if let tv = scrollView.documentView as? AgentInputCustomTextView {
            if tv.string != text {
                let savedRanges = tv.selectedRanges
                tv.string = text
                tv.selectedRanges = savedRanges
                tv.needsDisplay = true
                DispatchQueue.main.async {
                    tv.recalculateHeight()
                }
            }
            tv.textColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
            tv.insertionPointColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
            tv.onSend = onSend
            tv.onFocusChanged = onFocusChanged
            tv.onImagesPasted = onImagesPasted
        }

        context.coordinator.focusTextViewIfRequested()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentAutoGrowingTextView
        weak var textView: AgentInputCustomTextView?
        weak var scrollView: NSScrollView?
        private var heightBinding: Binding<CGFloat>?
        private var minHeight: CGFloat = 22
        private var maxHeight: CGFloat = 160
        private var lastReportedHeight: CGFloat?
        private var lastFocusRequest: Int?

        init(_ parent: AgentAutoGrowingTextView) {
            self.parent = parent
        }

        func update(from parent: AgentAutoGrowingTextView, heightBinding: Binding<CGFloat>) {
            self.parent = parent
            self.heightBinding = heightBinding
            self.minHeight = parent.minHeight
            self.maxHeight = parent.maxHeight
        }

        func focusTextViewIfRequested() {
            guard let previousFocusRequest = lastFocusRequest else {
                self.lastFocusRequest = parent.focusRequest
                return
            }
            guard parent.focusRequest != previousFocusRequest else { return }
            lastFocusRequest = parent.focusRequest

            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        func reportHeight(_ rawHeight: CGFloat) {
            let newHeight = ceil(min(maxHeight, max(minHeight, rawHeight)))
            if let lastReportedHeight, abs(lastReportedHeight - newHeight) < 1.0 {
                return
            }
            lastReportedHeight = newHeight

            DispatchQueue.main.async { [weak self] in
                guard let self, let heightBinding = self.heightBinding else { return }
                guard abs(heightBinding.wrappedValue - newHeight) >= 1.0 else { return }
                heightBinding.wrappedValue = newHeight
            }
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            tv.recalculateHeight()
            tv.needsDisplay = true
        }

        public func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged?(true)
        }

        public func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged?(false)
        }
    }
}

public final class AgentInputCustomTextView: NSTextView {
    public var placeholderString: String?
    public var onSend: (() -> Void)?
    public var onHeightChanged: ((CGFloat) -> Void)?
    public var onFocusChanged: ((Bool) -> Void)?
    public var onImagesPasted: (([AgentImageAttachment]) -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocusChanged?(true)
        }
        return didBecomeFirstResponder
    }

    public override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            onFocusChanged?(false)
        }
        return didResignFirstResponder
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Enter
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                recalculateHeight()
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
        recalculateHeight()
    }

    public override func paste(_ sender: Any?) {
        let images = ImageAttachmentHelpers.extractImages(from: .general)
        if !images.isEmpty {
            onImagesPasted?(images)
            if let string = NSPasteboard.general.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                super.paste(sender)
            }
            recalculateHeight()
            return
        }
        super.paste(sender)
        recalculateHeight()
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let images = ImageAttachmentHelpers.extractImages(from: sender.draggingPasteboard)
        if !images.isEmpty {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = ImageAttachmentHelpers.extractImages(from: sender.draggingPasteboard)
        if !images.isEmpty {
            onImagesPasted?(images)
            return true
        }
        return super.performDragOperation(sender)
    }

    public func recalculateHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let usedRect = lm.usedRect(for: tc)
        let newH = ceil(usedRect.height)
        onHeightChanged?(max(22, newH))
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder = placeholderString {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor
            ]
            let rect = NSRect(x: 0, y: 0, width: bounds.width, height: 18)
            (placeholder as NSString).draw(in: rect, withAttributes: attrs)
        }
    }
}

public struct AgentInputView: View {
    @Binding public var text: String
    @ObservedObject public var agentManager: AgentSessionManager
    public var theme: Theme
    public var accentColor: Color
    @Binding public var isCollapsed: Bool
    public var onSend: (String, [AgentImageAttachment]) -> Void
    public var onCancel: () -> Void
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)?

    @State private var attachedImages: [AgentImageAttachment] = []
    @State private var previewImageIndex: Int? = nil
    @State private var isSettingsPopoverPresented: Bool = false
    @Binding private var calculatedHeight: CGFloat
    @State private var isContextUsageHovered: Bool = false
    @State private var isSendButtonHovered: Bool = false
    @State private var isInputFocused: Bool = false
    @State private var inputFocusRequest: Int = 0

    public init(
        text: Binding<String>,
        agentManager: AgentSessionManager,
        theme: Theme,
        accentColor: Color = .accentColor,
        isCollapsed: Binding<Bool>,
        calculatedHeight: Binding<CGFloat>,
        onSend: @escaping (String, [AgentImageAttachment]) -> Void,
        onCancel: @escaping () -> Void,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil
    ) {
        self._text = text
        self.agentManager = agentManager
        self.theme = theme
        self.accentColor = accentColor
        self._isCollapsed = isCollapsed
        self._calculatedHeight = calculatedHeight
        self.onSend = onSend
        self.onCancel = onCancel
        self.onReview = onReview
        self.onPreviewImages = onPreviewImages
    }

    public init(
        text: Binding<String>,
        agentManager: AgentSessionManager,
        theme: Theme,
        accentColor: Color = .accentColor,
        isCollapsed: Binding<Bool>,
        calculatedHeight: Binding<CGFloat>,
        onSend: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil
    ) {
        self._text = text
        self.agentManager = agentManager
        self.theme = theme
        self.accentColor = accentColor
        self._isCollapsed = isCollapsed
        self._calculatedHeight = calculatedHeight
        self.onSend = { prompt, _ in onSend(prompt) }
        self.onCancel = onCancel
        self.onReview = onReview
        self.onPreviewImages = onPreviewImages
    }

    private var isBusy: Bool {
        agentManager.status == .busy || agentManager.status == .connecting || agentManager.initializationState == .starting
    }

    private var shouldShowLiveEditedSummary: Bool {
        agentManager.liveEditedSummary != nil &&
            (isBusy || agentManager.messages.last?.isStreaming == true)
    }

    public var body: some View {
        ZStack {
            if isCollapsed {
                collapsedView
            } else {
                expandedView
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAttachImages"))) { notification in
            if let newImages = notification.userInfo?["images"] as? [AgentImageAttachment], !newImages.isEmpty {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    attachedImages.append(contentsOf: newImages)
                    isCollapsed = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffDeleteDraftImage"))) { notification in
            if let delIdx = notification.userInfo?["index"] as? Int {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if delIdx >= 0 && delIdx < attachedImages.count {
                        attachedImages.remove(at: delIdx)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffUpdateDraftImage"))) { notification in
            guard let index = notification.userInfo?["index"] as? Int,
                  let image = notification.userInfo?["image"] as? AgentImageAttachment,
                  index >= 0,
                  index < attachedImages.count else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                attachedImages[index] = image
            }
        }
        .overlay {
            if onPreviewImages == nil, previewImageIndex != nil && !attachedImages.isEmpty {
                AgentImagePreviewModalView(
                    images: attachedImages,
                    selectedIndex: $previewImageIndex,
                    allowsEditing: true,
                    onDelete: { delIdx in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if delIdx >= 0 && delIdx < attachedImages.count {
                                attachedImages.remove(at: delIdx)
                            }
                        }
                    },
                    onEdit: { index, image in
                        guard index >= 0, index < attachedImages.count else { return }
                        attachedImages[index] = image
                    },
                    theme: theme
                )
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var expandedView: some View {
        VStack(spacing: 8) {
            // Live changed files top banner
            ZStack {
                if shouldShowLiveEditedSummary, let liveSummary = agentManager.liveEditedSummary {
                    AgentLiveChangesBannerView(
                        summary: liveSummary,
                        theme: theme,
                        accentColor: accentColor,
                        onReview: onReview
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.14), value: shouldShowLiveEditedSummary)

            VStack(spacing: 8) {
                // Attached images miniature strip
                if !attachedImages.isEmpty {
                    AgentInputAttachmentThumbnailView(
                        images: attachedImages,
                        theme: theme,
                        onSelect: { index in
                            if let onPreviewImages = onPreviewImages {
                                onPreviewImages(attachedImages, index, true)
                            } else {
                                previewImageIndex = index
                            }
                        },
                        onDelete: { index in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if index >= 0 && index < attachedImages.count {
                                    attachedImages.remove(at: index)
                                }
                            }
                        }
                    )
                    .padding(.top, 2)
                    .padding(.horizontal, 4)
                }

                // Main text input row with multi-line smooth scrolling
                HStack(alignment: .top, spacing: 8) {
                    AgentAutoGrowingTextView(
                        text: $text,
                        placeholder: "Ask anything...",
                        theme: theme,
                        minHeight: 22,
                        maxHeight: 160,
                        focusRequest: inputFocusRequest,
                        calculatedHeight: $calculatedHeight,
                        onSend: handleSend,
                        onFocusChanged: { focused in
                            isInputFocused = focused
                        },
                        onImagesPasted: { newImages in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                attachedImages.append(contentsOf: newImages)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: calculatedHeight)
                }
                .padding(.top, attachedImages.isEmpty ? 4 : 0)
                .padding(.horizontal, 4)

                // Bottom toolbar row inside input capsule
                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    agentStatusOrSettingsView

                    // Context Usage Percentage (if available)
                    if let pct = agentManager.contextUsagePercentage {
                        contextUsageRing(percentage: pct)
                    }

                    // Collapse input button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isCollapsed = true
                        }
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                            .padding(2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide / Collapse Input")
                    .agentInputInteractiveHover(
                        cornerRadius: 7,
                        horizontalPadding: 4,
                        verticalPadding: 3
                    )

                    sendButton
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(theme.inputBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(accentColor.opacity(isInputFocused ? 0.035 : 0))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                isInputFocused ? accentColor.opacity(0.62) : Color(theme.excerptHeaderBorder).opacity(0.8),
                                lineWidth: isInputFocused ? 1.4 : 1.2
                            )
                    )
                    .shadow(
                        color: isInputFocused ? accentColor.opacity(0.16) : .clear,
                        radius: isInputFocused ? 14 : 0,
                        y: isInputFocused ? 2 : 0
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                inputFocusRequest &+= 1
            }
            .animation(.easeOut(duration: 0.16), value: isInputFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var agentStatusOrSettingsView: some View {
        if agentManager.initializationState == .starting || agentManager.status == .connecting {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
                Text(agentManager.agentTitle)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(Color(theme.foreground).opacity(0.78))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(theme.foreground).opacity(0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(theme.excerptHeaderBorder).opacity(0.55), lineWidth: 1)
            )
            .help("Starting \(agentManager.agentTitle)…")
        } else if !agentManager.availableAgentSettings.isEmpty {
            agentSettingsMenu
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5.5, height: 5.5)
                Text(agentManager.agentTitle)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(Color(theme.foreground).opacity(0.88))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(theme.foreground).opacity(0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(theme.excerptHeaderBorder).opacity(0.7), lineWidth: 1)
            )
        }
    }

    private struct OptionGroup: Identifiable {
        let id: String
        let groupName: String
        let items: [ACPConfigOption.OptionValue]
    }

    private func groupOptionsByPrefix(_ values: [ACPConfigOption.OptionValue]) -> [OptionGroup] {
        var dict: [String: [ACPConfigOption.OptionValue]] = [:]
        var order: [String] = []

        for val in values {
            let groupName: String
            if let slashIndex = val.name.firstIndex(of: "/") {
                groupName = String(val.name[..<slashIndex]).trimmingCharacters(in: .whitespaces)
            } else if let slashIndex = val.value.firstIndex(of: "/") {
                groupName = String(val.value[..<slashIndex]).capitalized
            } else {
                groupName = "General"
            }

            if dict[groupName] == nil {
                order.append(groupName)
                dict[groupName] = []
            }
            dict[groupName]?.append(val)
        }

        return order.map { OptionGroup(id: $0, groupName: $0, items: dict[$0] ?? []) }
    }

    private var agentSettingsMenu: some View {
        Menu {
            ForEach(agentManager.availableAgentSettings) { option in
                if let values = option.options, !values.isEmpty {
                    Menu {
                        if values.count > 20 {
                            let groups = groupOptionsByPrefix(values)
                            if groups.count > 1 {
                                ForEach(groups) { group in
                                    Menu(group.groupName) {
                                        ForEach(group.items, id: \.value) { value in
                                            optionValueButton(option: option, value: value)
                                        }
                                    }
                                }
                            } else {
                                ForEach(values, id: \.value) { value in
                                    optionValueButton(option: option, value: value)
                                }
                            }
                        } else {
                            ForEach(values, id: \.value) { value in
                                optionValueButton(option: option, value: value)
                            }
                        }
                    } label: {
                        settingsOptionRow(option)
                    }
                } else if option.type?.lowercased() == "boolean" {
                    Button {
                        let nextValue = option.currentValue?.lowercased() == "true" ? "false" : "true"
                        agentManager.selectConfigOption(id: option.id, value: nextValue)
                    } label: {
                        settingsOptionRow(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(agentSettingsSummary)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(Color(theme.foreground).opacity(0.92))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(theme.foreground).opacity(0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color(theme.excerptHeaderBorder).opacity(0.7), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Agent settings")
        .agentInputInteractiveHover(cornerRadius: 15, horizontalPadding: 2, verticalPadding: 2)
    }

    private func optionValueButton(option: ACPConfigOption, value: ACPConfigOption.OptionValue) -> some View {
        Button {
            agentManager.selectConfigOption(id: option.id, value: value.value)
        } label: {
            HStack(spacing: 8) {
                Text(value.name)
                if option.currentValue == value.value {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
        }
    }

    private var agentSettingsSummary: String {
        var parts: [String] = []
        let model = agentManager.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            parts.append(model)
        }
        let effort = agentManager.selectedReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty {
            parts.append(effort)
        }
        if parts.isEmpty {
            let mode = agentManager.selectedAgentMode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mode.isEmpty {
                parts.append(mode)
            }
        }
        if parts.isEmpty {
            for opt in agentManager.availableAgentSettings {
                if let cur = opt.currentValue, !cur.isEmpty {
                    let name = opt.options?.first(where: { $0.value == cur })?.name ?? cur
                    parts.append(name)
                    break
                }
            }
        }
        if parts.isEmpty {
            parts.append(agentManager.agentTitle)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func settingsOptionRow(_ option: ACPConfigOption) -> some View {
            HStack(spacing: 10) {
            Text(settingsTitle(for: option))
            Spacer(minLength: 18)
            Text(settingsValue(for: option))
                .foregroundColor(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
        }
    }

    private func settingsTitle(for option: ACPConfigOption) -> String {
        option.name
    }

    private func settingsValue(for option: ACPConfigOption) -> String {
        if let current = option.currentValue,
           let selected = option.options?.first(where: { $0.value == current }) {
            return selected.name
        }
        if option.type?.lowercased() == "boolean" {
            return option.currentValue?.lowercased() == "true" ? "On" : "Off"
        }
        return option.currentValue ?? "—"
    }

    private func contextUsageRing(percentage: Int) -> some View {
        let progress = CGFloat(max(0, min(100, percentage))) / 100

        return ZStack {
            Circle()
                .stroke(Color(theme.gutterForeground).opacity(0.22), lineWidth: 1.5)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color(theme.gutterForeground).opacity(isContextUsageHovered ? 0.82 : 0.58),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .overlay(alignment: .top) {
            if isContextUsageHovered {
                Text("\(percentage)%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(theme.foreground))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .fixedSize()
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color(theme.excerptHeaderBorder).opacity(0.7), lineWidth: 1)
                    )
                    .offset(y: -20)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .scaleEffect(isContextUsageHovered ? 1.08 : 1)
        .animation(.easeOut(duration: 0.15), value: isContextUsageHovered)
        .onHover { hovering in
            isContextUsageHovered = hovering
        }
        .overlay(AgentInputPointingHandCursorView())
        .accessibilityLabel("Context usage \(percentage)%")
        .help("Context usage: \(percentage)%")
    }

    private var sendButton: some View {
        let canSend = (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty) && agentManager.canAcceptPrompt

        return ZStack {
            Button(action: onCancel) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.82))
            }
            .buttonStyle(.plain)
            .help("Stop Generation")
            .opacity(isBusy ? 1 : 0)
            .scaleEffect(isBusy ? 1 : 0.82)
            .allowsHitTesting(isBusy)
            .accessibilityHidden(!isBusy)

            Button(action: handleSend) {
                ZStack {
                    Circle()
                        .fill(canSend ? accentColor : Color.secondary.opacity(0.18))
                        .frame(width: 26, height: 26)

                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(canSend ? .white : Color(theme.gutterForeground).opacity(0.6))
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(agentManager.initializationState == .starting ? "Starting agent…" : "Send Prompt (Enter)")
            .opacity(isBusy ? 0 : 1)
            .scaleEffect(isBusy ? 0.82 : 1)
            .allowsHitTesting(!isBusy)
            .accessibilityHidden(isBusy)
        }
        .frame(width: 26, height: 26)
        .animation(.easeInOut(duration: 0.18), value: isBusy)
        .agentInputInteractiveHover(cornerRadius: 13)
        .scaleEffect(isSendButtonHovered ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: isSendButtonHovered)
        .onHover { hovering in
            isSendButtonHovered = hovering
        }
    }

    @ViewBuilder
    private var collapsedView: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCollapsed = false
            }
        }) {
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(theme.foreground).opacity(0.9))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    Circle()
                        .stroke(Color(theme.excerptHeaderBorder).opacity(0.85), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Expand Input")
        .accessibilityLabel(text.isEmpty ? "Expand input" : "Expand input with draft text")
    }

    private func handleSend() {
        guard !isBusy else { return }
        guard agentManager.canAcceptPrompt else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachedImages.isEmpty else { return }
        let imagesToSend = attachedImages
        attachedImages = []
        text = ""
        calculatedHeight = 22
        onSend(trimmed, imagesToSend)
    }
}

private struct AgentInputInteractiveHoverModifier: ViewModifier {
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .overlay(AgentInputPointingHandCursorView())
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct AgentInputPointingHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> AgentInputPointingHandNSView {
        AgentInputPointingHandNSView()
    }

    func updateNSView(_ nsView: AgentInputPointingHandNSView, context: Context) {}
}

private final class AgentInputPointingHandNSView: NSView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea, trackingArea.rect == bounds {
            return
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .cursorUpdate
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    // Keep the cursor view transparent to clicks so the underlying SwiftUI
    // Button/Menu still receives the event.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension View {
    func agentInputInteractiveHover(
        cornerRadius: CGFloat = 6,
        horizontalPadding: CGFloat = 0,
        verticalPadding: CGFloat = 0
    ) -> some View {
        modifier(
            AgentInputInteractiveHoverModifier(
                cornerRadius: cornerRadius,
                horizontalPadding: horizontalPadding,
                verticalPadding: verticalPadding
            )
        )
    }
}

public struct AgentLiveChangesBannerView: View {
    public let summary: AgentEditedFilesSummary
    public let theme: Theme
    public let accentColor: Color
    public var onReview: ((AgentEditedFilesSummary) -> Void)?

    @State private var isHovered: Bool = false

    public init(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        accentColor: Color,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil
    ) {
        self.summary = summary
        self.theme = theme
        self.accentColor = accentColor
        self.onReview = onReview
    }

    public var body: some View {
        Button(action: {
            onReview?(summary)
        }) {
            HStack(spacing: 8) {
                // Left section: pencil icon, files count, +/- counters
                HStack(spacing: 7) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accentColor)

                    Text(summary.files.count == 1 ? "1 file changed" : "\(summary.files.count) files changed")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))

                    if summary.totalAdditions > 0 {
                        Text("+\(summary.totalAdditions)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.28, green: 0.82, blue: 0.45))
                    }

                    if summary.totalDeletions > 0 {
                        Text("-\(summary.totalDeletions)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(red: 0.96, green: 0.32, blue: 0.28))
                    }
                }

                Spacer(minLength: 8)

                // Right section: Review ↗
                HStack(spacing: 3) {
                    Text("Review")
                        .font(.system(size: 12.5, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10.5, weight: .bold))
                }
                .foregroundColor(accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(accentColor.opacity(isHovered ? 0.12 : 0.05))
                    )
            )
            .shadow(
                color: accentColor.opacity(isHovered ? 0.14 : 0.04),
                radius: isHovered ? 8 : 4,
                y: 1
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .overlay(AgentInputPointingHandCursorView())
        .help("Review live changes in MultiBuffer (Read-Only)")
    }
}
