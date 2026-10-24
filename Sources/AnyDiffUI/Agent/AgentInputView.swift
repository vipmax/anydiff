import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    public var onDeleteBackwardWhenEmpty: (() -> Void)?

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
        onImagesPasted: (([AgentImageAttachment]) -> Void)? = nil,
        onDeleteBackwardWhenEmpty: (() -> Void)? = nil
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
        self.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
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
        textView.setupDragDrop()
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
        textView.string = text
        context.coordinator.lastKnownText = text
        context.coordinator.lastObservedText = text
        if !text.isEmpty {
            textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        textView.onSend = onSend
        textView.onFocusChanged = onFocusChanged
        textView.onImagesPasted = onImagesPasted
        textView.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
        textView.onHeightChanged = { [weak coordinator = context.coordinator] newHeight in
            coordinator?.reportHeight(newHeight)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        DispatchQueue.main.async {
            textView.recalculateHeight()
        }

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self, heightBinding: _calculatedHeight)

        if let tv = scrollView.documentView as? AgentInputCustomTextView {
            let isFocused = (tv.window?.firstResponder == tv)
            let isTyping = isFocused && tv.string == context.coordinator.lastKnownText
            let externalClear = (text != context.coordinator.lastObservedText && text.isEmpty)
            let externalReplaced = (text != context.coordinator.lastObservedText && !tv.string.hasPrefix(text) && !text.hasPrefix(tv.string))
            let shouldUpdateText: Bool

            if tv.string == text {
                shouldUpdateText = false
            } else if !isFocused {
                shouldUpdateText = true
            } else if externalClear || externalReplaced || !isTyping {
                shouldUpdateText = true
            } else {
                shouldUpdateText = false
            }

            if shouldUpdateText {
                tv.string = text
                context.coordinator.lastKnownText = text
                context.coordinator.lastObservedText = text
                tv.selectedRange = NSRange(location: (text as NSString).length, length: 0)
                tv.needsDisplay = true
                DispatchQueue.main.async {
                    tv.recalculateHeight()
                }
            } else if tv.string == text {
                context.coordinator.lastObservedText = text
            }
            tv.textColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
            tv.insertionPointColor = NSColor(cgColor: theme.foreground.cgColor) ?? .textColor
            tv.onSend = onSend
            tv.onFocusChanged = onFocusChanged
            tv.onImagesPasted = onImagesPasted
            tv.onDeleteBackwardWhenEmpty = onDeleteBackwardWhenEmpty
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
        var lastKnownText: String = ""
        var lastObservedText: String = ""

        init(_ parent: AgentAutoGrowingTextView) {
            self.parent = parent
            self.lastKnownText = parent.text
            self.lastObservedText = parent.text
        }

        func update(from parent: AgentAutoGrowingTextView, heightBinding: Binding<CGFloat>) {
            self.parent = parent
            self.heightBinding = heightBinding
            self.minHeight = parent.minHeight
            self.maxHeight = parent.maxHeight
        }

        func focusTextViewIfRequested() {
            let shouldFocus: Bool
            if let previousFocusRequest = lastFocusRequest {
                shouldFocus = (parent.focusRequest != previousFocusRequest)
            } else {
                shouldFocus = (parent.focusRequest > 0)
            }
            lastFocusRequest = parent.focusRequest
            guard shouldFocus else { return }

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
            lastKnownText = tv.string
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
    public var onDeleteBackwardWhenEmpty: (() -> Void)?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupDragDrop()
        }
    }

    public func setupDragDrop() {
        registerForDraggedTypes([
            .fileURL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.image"),
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            .string
        ])
    }

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
        if event.keyCode == 51 { // Backspace
            if string.isEmpty {
                onDeleteBackwardWhenEmpty?()
                return
            }
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
        if ImageAttachmentHelpers.hasImages(in: sender.draggingPasteboard) {
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

public struct AgentInputTextBlockState: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
    public var height: CGFloat
    public var focusRequest: Int

    public init(id: String = UUID().uuidString, text: String = "", height: CGFloat = 22, focusRequest: Int = 0) {
        self.id = id
        self.text = text
        self.height = height
        self.focusRequest = focusRequest
    }
}

public enum AgentInputBlock: Identifiable, Equatable, Sendable {
    case text(AgentInputTextBlockState)
    case quote(id: String, quote: SelectionQuote)

    public var id: String {
        switch self {
        case .text(let state): return state.id
        case .quote(let id, _): return id
        }
    }

    public var isQuote: Bool {
        if case .quote = self { return true }
        return false
    }

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    public var asPromptBlock: PromptBlock {
        switch self {
        case .text(let state): return .text(state.text)
        case .quote(_, let quote): return .quote(quote)
        }
    }
}

public struct AgentInputView: View {
    @Binding public var text: String
    @ObservedObject public var agentManager: AgentSessionManager
    public var theme: Theme
    public var accentColor: Color
    public var onSend: (String, [AgentImageAttachment]) -> Void
    public var onCancel: () -> Void
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)?

    @Binding public var attachedImages: [AgentImageAttachment]
    @State private var previewImageIndex: Int? = nil
    @Binding private var calculatedHeight: CGFloat
    @State private var isInputFocused: Bool = false
    @State private var inputFocusRequest: Int = 0
    @State private var isInputDropTargeted: Bool = false
    @ObservedObject private var quoteStore = SelectionQuoteStore.shared
    @State private var blocks: [AgentInputBlock] = [.text(AgentInputTextBlockState(text: ""))]
    @State private var focusedBlockId: String = ""
    @State private var blocksContentHeight: CGFloat = 0

    public init(
        text: Binding<String>,
        attachedImages: Binding<[AgentImageAttachment]>? = nil,
        agentManager: AgentSessionManager,
        theme: Theme,
        accentColor: Color = .accentColor,
        isCollapsed: Binding<Bool>? = nil,
        calculatedHeight: Binding<CGFloat>,
        onSend: @escaping (String, [AgentImageAttachment]) -> Void,
        onCancel: @escaping () -> Void,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil
    ) {
        self._text = text
        self._attachedImages = attachedImages ?? Binding(
            get: { agentManager.draftAttachments },
            set: { agentManager.draftAttachments = $0 }
        )
        self.agentManager = agentManager
        self.theme = theme
        self.accentColor = accentColor
        self._calculatedHeight = calculatedHeight
        self.onSend = onSend
        self.onCancel = onCancel
        self.onReview = onReview
        self.onPreviewImages = onPreviewImages
    }

    public init(
        text: Binding<String>,
        attachedImages: Binding<[AgentImageAttachment]>? = nil,
        agentManager: AgentSessionManager,
        theme: Theme,
        accentColor: Color = .accentColor,
        isCollapsed: Binding<Bool>? = nil,
        calculatedHeight: Binding<CGFloat>,
        onSend: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onReview: ((AgentEditedFilesSummary) -> Void)? = nil,
        onPreviewImages: (([AgentImageAttachment], Int, Bool) -> Void)? = nil
    ) {
        self._text = text
        self._attachedImages = attachedImages ?? Binding(
            get: { agentManager.draftAttachments },
            set: { agentManager.draftAttachments = $0 }
        )
        self.agentManager = agentManager
        self.theme = theme
        self.accentColor = accentColor
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
        expandedView
            .onDrop(of: [UTType.image, UTType.fileURL, UTType.png, UTType.jpeg, UTType.tiff, UTType.webP, UTType.heic, UTType.url, UTType.data, UTType.item], isTargeted: $isInputDropTargeted) { providers in
                ImageAttachmentHelpers.extractImages(from: providers) { droppedImages in
                    guard !droppedImages.isEmpty else { return }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        attachedImages = ImageAttachmentHelpers.deduplicateAttachments(attachedImages + droppedImages)
                    }
                }
                return true
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAttachImages"))) { notification in
                if let newImages = notification.userInfo?["images"] as? [AgentImageAttachment], !newImages.isEmpty {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        attachedImages = ImageAttachmentHelpers.deduplicateAttachments(attachedImages + newImages)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentSubmitPrompt"))) { _ in
                handleSend()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffFocusAgentInput"))) { _ in
                inputFocusRequest &+= 1
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
        .onAppear {
            if !text.isEmpty && blocks.count == 1, case .text(var state) = blocks[0], state.text.isEmpty {
                state.text = text
                blocks[0] = .text(state)
                focusedBlockId = state.id
            }
        }
        .onChange(of: text) { newText in
            guard !hasQuotes else { return }
            if blocks.count == 1, case .text(var state) = blocks[0] {
                if state.text != newText {
                    state.text = newText
                    blocks[0] = .text(state)
                }
            }
        }
    }

    @ViewBuilder
    private var expandedView: some View {
        VStack(spacing: 8) {
            // Live changed files top banner
            if shouldShowLiveEditedSummary, let liveSummary = agentManager.liveEditedSummary {
                AgentLiveChangesBannerView(
                    summary: liveSummary,
                    theme: theme,
                    accentColor: accentColor,
                    onReview: onReview
                )
                .transition(.opacity)
            }

            if !agentManager.promptQueue.isEmpty {
                AgentPromptQueueView(
                    queue: agentManager.promptQueue,
                    theme: theme,
                    accentColor: accentColor,
                    isAgentBusy: isBusy,
                    onEdit: { id, newText in
                        agentManager.updateQueuedPrompt(id: id, text: newText)
                    },
                    onDelete: { id in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            agentManager.removeQueuedPrompt(id: id)
                        }
                    },
                    onMove: { id, direction in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            agentManager.moveQueuedPrompt(id: id, direction: direction)
                        }
                    },
                    onRunNow: { id in
                        agentManager.runQueuedPrompt(id: id, workingDirectory: "")
                    },
                    onClearQueue: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            agentManager.clearQueue()
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
            }

            HStack(alignment: .top, spacing: 12) {
                // User avatar on the left, dynamically sized to user avatar size
                AgentAvatarProvider.userAvatarSwiftUIView()

                VStack(alignment: .leading, spacing: 6) {
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
                    }

                    // Blocks flow (interleaved quotes and text)
                    if !hasQuotes, blocks.count == 1, case .text(let state) = blocks[0] {
                        HStack(alignment: .top, spacing: 8) {
                            AgentAutoGrowingTextView(
                                text: Binding(
                                    get: { state.text },
                                    set: { newText in updateTextBlock(id: state.id, text: newText) }
                                ),
                                placeholder: (!agentManager.authMethods.isEmpty || agentManager.isAuthenticating) ? "Sign in above to start chatting..." : "Ask anything...",
                                theme: theme,
                                minHeight: 22,
                                maxHeight: 160,
                                focusRequest: state.focusRequest + inputFocusRequest,
                                calculatedHeight: Binding(
                                    get: { state.height },
                                    set: { newH in updateTextBlockHeight(id: state.id, height: newH) }
                                ),
                                onSend: handleSend,
                                onFocusChanged: { focused in
                                    isInputFocused = focused
                                    if focused { focusedBlockId = state.id }
                                },
                                onImagesPasted: { newImages in
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                        attachedImages = ImageAttachmentHelpers.deduplicateAttachments(attachedImages + newImages)
                                    }
                                }
                            )
                            .padding(.top, 1)
                            .frame(maxWidth: .infinity)
                            .frame(height: state.height + 1)
                        }
                    } else {
                        let currentHeight = blocksContentHeight > 0 ? blocksContentHeight : estimatedBlocksHeight
                        let clampedHeight = min(max(currentHeight, 24), 280)

                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 8) {
                                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                                    switch block {
                                    case .quote(let id, let quote):
                                        quoteBadgeView(id: id, quote: quote)

                                    case .text(let state):
                                        let placeholder = (index == 0 && blocks.first?.isText == true && blocks.dropFirst().first?.isQuote == true)
                                            ? "Add context before quote (optional)..."
                                            : "Ask anything, add comment or instructions..."
                                        AgentAutoGrowingTextView(
                                            text: Binding(
                                                get: { state.text },
                                                set: { newText in updateTextBlock(id: state.id, text: newText) }
                                            ),
                                            placeholder: placeholder,
                                            theme: theme,
                                            minHeight: 22,
                                            maxHeight: 120,
                                            focusRequest: state.focusRequest + inputFocusRequest,
                                            calculatedHeight: Binding(
                                                get: { state.height },
                                                set: { newH in updateTextBlockHeight(id: state.id, height: newH) }
                                            ),
                                            onSend: handleSend,
                                            onFocusChanged: { focused in
                                                isInputFocused = focused
                                                if focused { focusedBlockId = state.id }
                                            },
                                            onImagesPasted: { newImages in
                                                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                                    attachedImages = ImageAttachmentHelpers.deduplicateAttachments(attachedImages + newImages)
                                                }
                                            },
                                            onDeleteBackwardWhenEmpty: {
                                                handleDeleteBackward(inBlockId: state.id, index: index)
                                            }
                                        )
                                        .padding(.top, index == 0 ? 1 : 0)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: state.height + (index == 0 ? 1 : 0))
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: AgentInputBlocksHeightPreferenceKey.self,
                                        value: geo.size.height
                                    )
                                }
                            )
                        }
                        .frame(height: clampedHeight)
                        .onPreferenceChange(AgentInputBlocksHeightPreferenceKey.self) { newHeight in
                            if newHeight > 0, abs(blocksContentHeight - newHeight) >= 1.0 {
                                blocksContentHeight = newHeight
                            }
                        }
                    }

                    if let quote = quoteStore.currentQuote,
                       !isAlreadyQuoted(quote) {
                        HStack {
                            Spacer()
                            Button(action: {
                                addQuote(quote)
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "quote.opening")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Quote selection (\(quote.label))")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(accentColor.opacity(0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(accentColor.opacity(0.35), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Quote selection (\(quote.label)): \"\(quote.text.prefix(60).replacingOccurrences(of: "\n", with: " "))\"")
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .background(Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                inputFocusRequest &+= 1
            }
        }
        .animation(.easeInOut(duration: 0.14), value: shouldShowLiveEditedSummary)
    }

    private func quoteBadgeView(id: String, quote: SelectionQuote) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "quote.opening")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(quote.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                        .lineLimit(1)

                    if let range = quote.lineRange {
                        Text(range.lowerBound == range.upperBound ? "line \(range.lowerBound)" : "lines \(range.lowerBound)–\(range.upperBound)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.85))
                            .lineLimit(1)
                    }
                }

                let cleanText = quote.text
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)

                Text(cleanText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Button(action: {
                removeQuoteBlock(id: id)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.75))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color(theme.foreground).opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("Remove quote")
            .accessibilityLabel("Remove quote from \(quote.label)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(theme.inputBackground).opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    private var hasQuotes: Bool {
        blocks.contains(where: \.isQuote)
    }

    private func isAlreadyQuoted(_ quote: SelectionQuote) -> Bool {
        blocks.contains { block in
            if case .quote(_, let q) = block {
                return q.id == quote.id || (q.text == quote.text && q.label == quote.label)
            }
            return false
        }
    }

    private func updateTextBlock(id: String, text: String) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        if case .text(var state) = blocks[index] {
            state.text = text
            blocks[index] = .text(state)
        }
        if !hasQuotes {
            self.text = text
        }
    }

    private var estimatedBlocksHeight: CGFloat {
        var total: CGFloat = 4
        for (i, block) in blocks.enumerated() {
            if i > 0 { total += 8 }
            switch block {
            case .quote:
                total += 38
            case .text(let state):
                total += max(22, state.height)
            }
        }
        return total
    }

    private func updateTextBlockHeight(id: String, height: CGFloat) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        if case .text(var state) = blocks[index] {
            state.height = height
            blocks[index] = .text(state)
        }
        if !hasQuotes {
            self.calculatedHeight = height
        } else {
            self.calculatedHeight = min(estimatedBlocksHeight, 280)
        }
    }

    private func addQuote(_ quote: SelectionQuote) {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let newQuoteId = "\(quote.id)-\(timestamp)"
        let quoteBlockId = "quote-\(timestamp)"
        let nextTextBlockId = "text-\(timestamp + 1)"

        let quoteBlock = AgentInputBlock.quote(
            id: quoteBlockId,
            quote: SelectionQuote(
                id: newQuoteId,
                text: quote.text,
                source: quote.source,
                label: quote.label,
                filePath: quote.filePath,
                displayPath: quote.displayPath,
                lineRange: quote.lineRange,
                language: quote.language
            )
        )
        let nextTextBlock = AgentInputBlock.text(
            AgentInputTextBlockState(
                id: nextTextBlockId,
                text: "",
                height: 22,
                focusRequest: 1
            )
        )

        withAnimation(.easeOut(duration: 0.16)) {
            if blocks.count == 1, case .text(let state) = blocks[0], state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks = [quoteBlock, nextTextBlock]
            } else {
                let focusIdx = blocks.firstIndex(where: { $0.id == focusedBlockId })
                let insertAt = (focusIdx != nil) ? focusIdx! + 1 : blocks.count
                blocks.insert(contentsOf: [quoteBlock, nextTextBlock], at: insertAt)
            }
            focusedBlockId = nextTextBlockId
        }

        quoteStore.clearQuote(scopedToId: quote.id)
    }

    private func removeQuoteBlock(id: String) {
        guard let quoteIdx = blocks.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            blocks.remove(at: quoteIdx)

            // If quote was between two text blocks, merge them
            let prevIdx = quoteIdx - 1
            let nextIdx = quoteIdx // now at quoteIdx because quote was removed
            if prevIdx >= 0, nextIdx < blocks.count,
               case .text(var prevState) = blocks[prevIdx],
               case .text(let nextState) = blocks[nextIdx] {
                let prevT = prevState.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let nextT = nextState.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let merged: String
                if !prevT.isEmpty && !nextT.isEmpty {
                    merged = "\(prevT)\n\n\(nextT)"
                } else {
                    merged = prevT.isEmpty ? nextT : prevT
                }
                prevState.text = merged
                prevState.focusRequest += 1
                blocks[prevIdx] = .text(prevState)
                blocks.remove(at: nextIdx)
                focusedBlockId = prevState.id
            } else if prevIdx >= 0, case .text(var prevState) = blocks[prevIdx] {
                prevState.focusRequest += 1
                blocks[prevIdx] = .text(prevState)
                focusedBlockId = prevState.id
            }

            if blocks.isEmpty {
                let fallbackState = AgentInputTextBlockState(text: "", height: 22, focusRequest: 1)
                blocks = [.text(fallbackState)]
                blocksContentHeight = 0
                focusedBlockId = fallbackState.id
                self.text = ""
                return
            }

            if !hasQuotes {
                let singleText = blocks.compactMap { block -> String? in
                    if case .text(let s) = block {
                        let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    return nil
                }.joined(separator: "\n\n")

                let singleId = blocks.first(where: \.isText)?.id ?? UUID().uuidString
                let finalState = AgentInputTextBlockState(id: singleId, text: singleText, height: 22, focusRequest: 1)
                blocks = [.text(finalState)]
                blocksContentHeight = 0
                focusedBlockId = singleId
                self.text = singleText
            }
        }
    }

    private func handleDeleteBackward(inBlockId: String, index: Int) {
        guard index > 0, let currentBlock = blocks.first(where: { $0.id == inBlockId }),
              case .text(let state) = currentBlock, state.text.isEmpty else { return }
        let prevBlock = blocks[index - 1]
        if case .quote(let quoteId, _) = prevBlock {
            removeQuoteBlock(id: quoteId)
        }
    }

    private var canSubmitPrompt: Bool {
        let hasText = blocks.contains { block in
            if case .text(let state) = block {
                return !state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
        let hasQuotes = self.hasQuotes
        let hasImages = !attachedImages.isEmpty
        return (hasText || hasQuotes || hasImages) && agentManager.canAcceptPrompt
    }

    private func handleSend() {
        guard agentManager.canAcceptPrompt else { return }
        guard canSubmitPrompt else { return }

        let promptBlocks = blocks.map(\.asPromptBlock)
        let finalPrompt = SelectionQuoteFormatter.formatPromptBlocks(promptBlocks)
        let imagesToSend = attachedImages

        attachedImages = []
        blocks = [.text(AgentInputTextBlockState(text: "", height: 22, focusRequest: 1))]
        blocksContentHeight = 0
        text = ""
        calculatedHeight = 22
        focusedBlockId = blocks[0].id

        onSend(finalPrompt, imagesToSend)
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

private struct AgentInputBlocksHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}


