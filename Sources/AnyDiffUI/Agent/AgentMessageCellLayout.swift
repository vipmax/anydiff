import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

extension AgentMessageCell {
    public static let iconLeft: CGFloat = 18
    public static var userAvatarSize: CGFloat { AgentAvatarProvider.currentUserAvatarSize }
    public static var agentAvatarSize: CGFloat { AgentAvatarProvider.currentAgentAvatarSize }
    public static var maxAvatarWidth: CGFloat { max(userAvatarSize, agentAvatarSize, 24) }
    public static let iconGap: CGFloat = 12
    public static var contentLeft: CGFloat { iconLeft + maxAvatarWidth + iconGap }
    public static var iconWidth: CGFloat { 24 }
    public static let rightMargin: CGFloat = 18
    public static let maxContentWidth: CGFloat = 800

    public static func contentWidth(for totalWidth: CGFloat) -> CGFloat {
        let available = max(50, totalWidth - contentLeft - rightMargin)
        return min(maxContentWidth, available)
    }

    private static let defaultBodyFirstLineHeight: CGFloat = ceil(
        NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 13, weight: .regular))
    )

    func firstLineHeight(for textView: NSTextView, width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return Self.defaultBodyFirstLineHeight
        }
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        if layoutManager.numberOfGlyphs > 0 {
            var lineGlyphRange = NSRange(location: 0, length: 0)
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: &lineGlyphRange)
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let charRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
                let clampedRange = NSIntersectionRange(charRange, NSRange(location: 0, length: textStorage.length))
                var hasAttachment = false
                if clampedRange.length > 0 {
                    textStorage.enumerateAttribute(.attachment, in: clampedRange) { value, _, stop in
                        if value is NSTextAttachment {
                            hasAttachment = true
                            stop.pointee = true
                        }
                    }
                }
                if hasAttachment {
                    return Self.defaultBodyFirstLineHeight
                }
            }
            if usedRect.height > 0 {
                // TextKit includes paragraphStyle.lineSpacing in line 0's usedRect
                // whenever another line follows, which would shift multi-line text
                // upward relative to single-line text and the composer input.
                let hasTrailingLine = NSMaxRange(lineGlyphRange) < layoutManager.numberOfGlyphs ||
                    layoutManager.extraLineFragmentTextContainer != nil
                var lineHeight = usedRect.height
                if hasTrailingLine, let textStorage = textView.textStorage, textStorage.length > 0 {
                    let charIndex = min(layoutManager.characterIndexForGlyph(at: 0), textStorage.length - 1)
                    if let paragraphStyle = textStorage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle,
                       paragraphStyle.lineSpacing > 0 {
                        lineHeight = max(1, lineHeight - paragraphStyle.lineSpacing)
                    }
                }
                return lineHeight
            }
        }
        let font = textView.font ?? NSFont.systemFont(ofSize: 13, weight: .regular)
        return ceil(layoutManager.defaultLineHeight(for: font))
    }

    private func verticalAlignmentOffsets(
        avatarSize: CGFloat,
        firstRowCenterOffset: CGFloat,
        minContentTop: CGFloat
    ) -> (avatarY: CGFloat, contentTop: CGFloat) {
        let baseAvatarTop: CGFloat = 2
        let avatarCenter = baseAvatarTop + avatarSize / 2
        let centeredContentTop = avatarCenter - firstRowCenterOffset
        if centeredContentTop >= minContentTop {
            return (baseAvatarTop, centeredContentTop)
        }
        let avatarY = minContentTop + firstRowCenterOffset - avatarSize / 2
        return (avatarY, minContentTop)
    }

    private func userFirstRowCenterOffset(contentWidth: CGFloat) -> CGFloat {
        if message.isQueued {
            return 12
        }
        if !userImageViews.isEmpty {
            return 12
        }
        if let firstView = userContentViews.first {
            if let tv = firstView as? AgentSelectableTextView {
                let wrapWidth = max(50, contentWidth - 6)
                return tv.textContainerInset.height + firstLineHeight(for: tv, width: wrapWidth) / 2
            }
            if firstView is AgentUserCodeBlockView {
                return 13
            }
            if let quoteBlock = firstView as? AgentUserQuoteBlockView {
                let textWidth = max(20, contentWidth - 22)
                return 7 + firstLineHeight(for: quoteBlock.tv, width: textWidth) / 2
            }
        }
        return Self.defaultBodyFirstLineHeight / 2
    }

    private func userImageSize(_ imageView: NSButton, contentWidth: CGFloat) -> CGSize {
        let imageSize = imageView.image?.size ?? CGSize(width: 240, height: 140)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: min(contentWidth, 420), height: 240)
        }
        let scale = min(1, contentWidth / imageSize.width, 480 / imageSize.width, 300 / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func userImagesHeight(contentWidth: CGFloat) -> CGFloat {
        guard !userImageViews.isEmpty else { return 0 }
        let imageHeight = userImageViews.reduce(CGFloat.zero) { total, imageView in
            total + userImageSize(imageView, contentWidth: contentWidth).height
        }
        return imageHeight + CGFloat(max(0, userImageViews.count - 1)) * 8
    }

    private func assistantFirstRowCenterOffset(contentWidth: CGFloat) -> CGFloat {
        if !thoughtHeaderButton.isHidden {
            return 10
        }
        if hasCompactTopThought {
            let thoughtWrapWidth = max(50, contentWidth - 6)
            return thoughtTextView.textContainerInset.height + firstLineHeight(for: thoughtTextView, width: thoughtWrapWidth) / 2
        }
        if let firstView = firstVisibleAssistantView() {
            if let tv = firstView as? AgentSelectableTextView {
                let wrapWidth = max(50, contentWidth - 6)
                return tv.textContainerInset.height + firstLineHeight(for: tv, width: wrapWidth) / 2
            }
            if firstView is AgentThoughtBlockView {
                return 10
            }
            if firstView is AgentToolGroupView {
                return isCompactMode ? 10 : 11
            }
            if firstView is AgentToolCardView {
                return isCompactMode ? 12 : 17
            }
            if firstView is AgentSimpleToolCallView {
                return 10
            }
            if firstView is AgentCodeBlockView {
                return 13
            }
            if firstView is AgentDividerView {
                return 8
            }
            if firstView.subviews.count >= 2,
               let quoteTV = firstView.subviews[1] as? AgentSelectableTextView {
                return 6 + firstLineHeight(for: quoteTV, width: max(50, contentWidth - 24)) / 2
            }
        }
        return Self.defaultBodyFirstLineHeight / 2
    }

    func invalidateLayoutCache() {
        cachedLayoutWidth = -1
        cachedLayoutHeight = 0
        cachedTextHeights.removeAll(keepingCapacity: true)
        layoutNeedsApplication = true
    }

    func measuredTextHeight(for view: NSView, attributedString: NSAttributedString, width: CGFloat) -> CGFloat {
        let key = TextMeasurementKey(view: ObjectIdentifier(view), width: Int((width * 2).rounded()))
        if let cached = cachedTextHeights[key] {
            return cached
        }
        let measured: CGFloat
        if let textView = view as? AgentSelectableTextView,
           let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            // Reuse TextKit's incremental layout state. This is especially
            // important for the single plain-text view used during streaming:
            // boundingRect would reflow the entire growing response for every
            // appended chunk.
            textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)
            measured = max(18, ceil(layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2))
        } else {
            measured = measureAttributedTextHeight(attributedString, maxWidth: width)
        }
        cachedTextHeights[key] = measured
        return measured
    }

    func assistantViewHeight(_ view: NSView, contentWidth: CGFloat) -> CGFloat {
        guard !view.isHidden, view.alphaValue > 0.01 else { return 0 }
        if view is AgentDividerView {
            return 16
        }
        if let thought = view as? AgentThoughtBlockView {
            return thought.measureHeight(width: contentWidth)
        }
        if let group = view as? AgentToolGroupView {
            return group.measureHeight(width: contentWidth)
        }
        if let simple = view as? AgentSimpleToolCallView {
            return simple.measureHeight(width: contentWidth)
        }
        if let card = view as? AgentToolCardView {
            return card.measureHeight(width: contentWidth)
        }
        if let card = view as? AgentEditedFilesCardView {
            return card.measureHeight(width: contentWidth)
        }
        if let tv = view as? AgentSelectableTextView {
            let wrapWidth = max(50, contentWidth - 6)
            return measuredTextHeight(for: tv, attributedString: tv.attributedString(), width: wrapWidth)
        }
        if let codeBlock = view as? AgentCodeBlockView {
            guard codeBlock.isExpanded else { return 26 }
            let codeHeight = measuredTextHeight(
                for: codeBlock.tv,
                attributedString: codeBlock.tv.attributedString(),
                width: contentWidth - 20
            )
            let visibleCodeHeight = min(maxCodeBlockHeight, codeHeight)
            return 26 + 6 + visibleCodeHeight + 10
        }
        if let mermaid = view as? MermaidBlockView {
            return mermaid.measuredHeight(for: contentWidth)
        }
        if view.subviews.count >= 2 {
            let quoteTV = view.subviews[1] as? AgentSelectableTextView
            let qHeight = measuredTextHeight(
                for: quoteTV ?? view,
                attributedString: quoteTV?.attributedString() ?? NSAttributedString(),
                width: contentWidth - 24
            )
            return qHeight + 12
        }
        return 28
    }

    @discardableResult
    func applyAssistantViewLayout(_ view: NSView, width: CGFloat, currentY: CGFloat, animated: Bool, spacing: CGFloat? = nil) -> CGFloat {
        guard !view.isHidden, view.alphaValue > 0.01 else { return 0 }
        let contentLeft = AgentMessageCell.contentLeft
        let contentWidth = AgentMessageCell.contentWidth(for: width)
        let height = assistantViewHeight(view, contentWidth: contentWidth)

        if let thought = view as? AgentThoughtBlockView {
            let frame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: height)
            if animated { thought.animator().frame = frame } else { thought.frame = frame }
            thought.applyLayout(width: contentWidth, animated: animated)
        } else if let group = view as? AgentToolGroupView {
            let frame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: height)
            if animated { group.animator().frame = frame } else { group.frame = frame }
            group.applyLayout(width: contentWidth, animated: animated)
        } else if let simple = view as? AgentSimpleToolCallView {
            let frame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: height)
            if animated { simple.animator().frame = frame } else { simple.frame = frame }
            simple.applyLayout(width: contentWidth)
        } else if let card = view as? AgentToolCardView {
            let frame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: height)
            if animated { card.animator().frame = frame } else { card.frame = frame }
            card.applyLayout(width: contentWidth, animated: animated)
        } else if let card = view as? AgentEditedFilesCardView {
            let frame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: height)
            if animated { card.animator().frame = frame } else { card.frame = frame }
            card.applyLayout(width: contentWidth)
        } else if let tv = view as? AgentSelectableTextView {
            let wrapWidth = max(50, contentWidth - 6)
            tv.textContainer?.containerSize = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
            let frame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: height)
            if animated { tv.animator().frame = frame } else { tv.frame = frame }
            tv.layer?.masksToBounds = true
            if tv.layer?.mask != nil {
                tv.layer?.mask = nil
            }
        } else if let divider = view as? AgentDividerView {
            let frame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: 16)
            if animated { divider.animator().frame = frame } else { divider.frame = frame }
            divider.applyLayout(width: contentWidth)
        } else if let codeBlock = view as? AgentCodeBlockView {
            let headerHeight: CGFloat = 26
            let isExpanded = codeBlock.isExpanded
            let codeHeight = isExpanded ? measuredTextHeight(
                for: codeBlock.tv,
                attributedString: codeBlock.tv.attributedString(),
                width: contentWidth - 20
            ) : 0
            let visibleCodeHeight = isExpanded ? min(maxCodeBlockHeight, codeHeight) : 0
            let totalCodeHeight = isExpanded ? headerHeight + 6 + visibleCodeHeight + 10 : headerHeight
            let blockFrame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: totalCodeHeight)
            let codeScrollFrame = NSRect(x: 10, y: headerHeight + 6, width: contentWidth - 20, height: visibleCodeHeight)
            let codeDocumentFrame = NSRect(x: 0, y: 0, width: contentWidth - 20, height: codeHeight)
            if isExpanded {
                codeBlock.tv.textContainer?.containerSize = NSSize(width: contentWidth - 20, height: .greatestFiniteMagnitude)
            }
            codeBlock.codeScrollView.isHidden = !isExpanded
            if animated {
                codeBlock.animator().frame = blockFrame
                codeBlock.header.animator().frame = NSRect(x: 0, y: 0, width: contentWidth, height: headerHeight)
                codeBlock.codeScrollView.animator().frame = codeScrollFrame
                codeBlock.tv.animator().frame = codeDocumentFrame
            } else {
                codeBlock.frame = blockFrame
                codeBlock.header.frame = NSRect(x: 0, y: 0, width: contentWidth, height: headerHeight)
                codeBlock.codeScrollView.frame = codeScrollFrame
                codeBlock.tv.frame = codeDocumentFrame
            }
        } else if let mermaid = view as? MermaidBlockView {
            let blockFrame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: height)
            if animated { mermaid.animator().frame = blockFrame } else { mermaid.frame = blockFrame }
            mermaid.applyLayout(width: contentWidth)
        } else if view.subviews.count >= 2 {
            let bar = view.subviews[0]
            let quoteTV = view.subviews[1] as? AgentSelectableTextView
            let qHeight = measuredTextHeight(
                for: quoteTV ?? view,
                attributedString: quoteTV?.attributedString() ?? NSAttributedString(),
                width: contentWidth - 24
            )
            let totalHeight = qHeight + 12
            let blockFrame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: totalHeight)
            let barFrame = NSRect(x: 4, y: 6, width: 3, height: max(16, totalHeight - 12))
            let quoteFrame = NSRect(x: 14, y: 6, width: contentWidth - 24, height: qHeight)
            if animated {
                view.animator().frame = blockFrame
                bar.animator().frame = barFrame
                quoteTV?.animator().frame = quoteFrame
            } else {
                view.frame = blockFrame
                bar.frame = barFrame
                quoteTV?.frame = quoteFrame
            }
        }

        let defaultSpacing: CGFloat = (view is AgentThoughtBlockView ? 2 : 6)
        return height + (spacing ?? defaultSpacing)
    }

    public func measureHeight(for width: CGFloat) -> CGFloat {
        guard message.hasVisibleContent else {
            cachedLayoutWidth = width
            cachedLayoutHeight = 0
            return 0
        }
        if abs(cachedLayoutWidth - width) < 0.5, cachedLayoutHeight > 0 {
            return cachedLayoutHeight
        }

        let contentWidth = AgentMessageCell.contentWidth(for: width)
        let height: CGFloat

        if message.role == .user {
            let isQueued = message.isQueued
            let queuedHeaderHeight: CGFloat = isQueued ? 24 : 0
            let queuedHeaderSpacing: CGFloat = isQueued ? 6 : 0

            let hasImages = !userImageViews.isEmpty
            let imagesHeight = userImagesHeight(contentWidth: contentWidth)

            let contentH: CGFloat
            if isQueued && isEditingQueuedMessage {
                let editorHeight = queuedEditorView.measuredHeight(for: contentWidth)
                contentH = queuedHeaderHeight + queuedHeaderSpacing + imagesHeight + (hasImages ? 8 : 0) + editorHeight
            } else {
                let hasContent = !userContentViews.isEmpty
                let fullTextHeight = hasContent ? measureUserContentViewsHeight(width: contentWidth) : 0
                contentH = queuedHeaderHeight + queuedHeaderSpacing + imagesHeight +
                    (hasImages && hasContent ? 8 : 0) + fullTextHeight
            }
            let userSize = AgentMessageCell.userAvatarSize
            let (avatarY, contentTop) = verticalAlignmentOffsets(
                avatarSize: userSize,
                firstRowCenterOffset: userFirstRowCenterOffset(contentWidth: contentWidth),
                minContentTop: 2
            )
            height = max(avatarY + userSize, contentTop + contentH) + 6
        } else {
            let agentSize = AgentAvatarProvider.currentAgentAvatarSize(for: agentId)
            let minContentTop: CGFloat = (!thoughtHeaderButton.isHidden || hasCompactTopThought) ? 3 : 5
            let (avatarY, contentTop) = verticalAlignmentOffsets(
                avatarSize: agentSize,
                firstRowCenterOffset: assistantFirstRowCenterOffset(contentWidth: contentWidth),
                minContentTop: minContentTop
            )
            var currentY = contentTop

            let firstViewIsTool = isToolCallView(firstVisibleAssistantView() ?? NSView())
            if !thoughtHeaderButton.isHidden {
                currentY += 22
                if isThoughtExpanded && !hasInlineThoughtParts {
                    let h = measuredTextHeight(
                        for: thoughtTextView,
                        attributedString: thoughtTextView.attributedString(),
                        width: contentWidth - 10
                    )
                    currentY += h + (firstViewIsTool ? (isCompactMode ? 10 : 14) : 8)
                } else if firstViewIsTool {
                    currentY += isCompactMode ? 5 : 8
                }
            } else if hasCompactTopThought {
                let h = measuredTextHeight(
                    for: thoughtTextView,
                    attributedString: thoughtTextView.attributedString(),
                    width: contentWidth
                )
                currentY += h + (firstViewIsTool ? (isCompactMode ? 10 : 14) : 8)
            }

            for (index, view) in orderedAssistantViews.enumerated() {
                guard !view.isHidden, view.alphaValue > 0.01 else { continue }
                if isEditedFilesCardView(view) {
                    currentY += isCompactMode ? 6 : 8
                }
                let spacing = spacingAfterAssistantView(at: index)
                currentY += assistantViewHeight(view, contentWidth: contentWidth) + spacing
            }

            height = max(avatarY + agentSize + 6, currentY)
        }

        cachedLayoutWidth = width
        cachedLayoutHeight = height
        return height
    }

    public func applyLayout(for width: CGFloat, animated: Bool) {
        guard message.hasVisibleContent else {
            frame = NSRect(x: 0, y: frame.origin.y, width: width, height: 0)
            roleIconView.isHidden = true
            avatarAuraView.stopAnimating(animated: false)
            return
        }
        let contentLeft = AgentMessageCell.contentLeft
        let contentWidth = AgentMessageCell.contentWidth(for: width)

        if message.role == .user {
            let userSize = AgentMessageCell.userAvatarSize
            let maxW = AgentMessageCell.maxAvatarWidth
            let iconX = AgentMessageCell.iconLeft + (maxW - userSize) / 2
            let (avatarY, contentTop) = verticalAlignmentOffsets(
                avatarSize: userSize,
                firstRowCenterOffset: userFirstRowCenterOffset(contentWidth: contentWidth),
                minContentTop: 2
            )
            let roleFrame = NSRect(x: iconX, y: avatarY, width: userSize, height: userSize)
            if animated { roleIconView.animator().frame = roleFrame } else { roleIconView.frame = roleFrame }
            avatarAuraView.frame = AgentAvatarAuraView.frame(around: roleFrame)
            stickyAvatarBaseY = roleFrame.origin.y
            if !animated { applyStickyAvatar() }

            let isQueued = message.isQueued
            let queuedHeaderHeight: CGFloat = isQueued ? 24 : 0
            let queuedHeaderSpacing: CGFloat = isQueued ? 6 : 0

            let hasImages = !userImageViews.isEmpty
            let imagesHeight = userImagesHeight(contentWidth: contentWidth)
            let hasContent = !userContentViews.isEmpty
            let fullTextHeight = hasContent ? measureUserContentViewsHeight(width: contentWidth) : 0

            let contentH: CGFloat
            if isQueued && isEditingQueuedMessage {
                let editorHeight = queuedEditorView.measuredHeight(for: contentWidth)
                contentH = queuedHeaderHeight + queuedHeaderSpacing + imagesHeight + (hasImages ? 8 : 0) + editorHeight
            } else {
                contentH = queuedHeaderHeight + queuedHeaderSpacing + imagesHeight +
                    (hasImages && hasContent ? 8 : 0) + fullTextHeight
            }

            let bubbleFrame = NSRect(
                x: contentLeft,
                y: contentTop,
                width: contentWidth,
                height: contentH
            )
            if animated {
                userBubbleView.animator().frame = bubbleFrame
            } else {
                userBubbleView.frame = bubbleFrame
            }
            userBubbleView.layer?.shadowColor = nil
            userBubbleView.layer?.shadowOpacity = 0.0

            var currentInsideY: CGFloat = 0
            if isQueued {
                queuedHeaderView.isHidden = false
                let qFrame = NSRect(x: 0, y: currentInsideY, width: contentWidth, height: queuedHeaderHeight)
                if animated { queuedHeaderView.animator().frame = qFrame } else { queuedHeaderView.frame = qFrame }
                queuedHeaderView.applyLayout(width: contentWidth)
                currentInsideY += queuedHeaderHeight + queuedHeaderSpacing
            } else {
                queuedHeaderView.isHidden = true
            }
            if hasImages {
                for btn in userImageViews {
                    let size = userImageSize(btn, contentWidth: contentWidth)
                    let imgFrame = NSRect(x: 0, y: currentInsideY, width: size.width, height: size.height)
                    if animated { btn.animator().frame = imgFrame } else { btn.frame = imgFrame }
                    currentInsideY += size.height + 8
                }
                currentInsideY -= 8
                currentInsideY += hasContent ? 8 : 0
            }

            userTextView.isHidden = true

            if isQueued && isEditingQueuedMessage {
                let editorH = queuedEditorView.measuredHeight(for: contentWidth)
                let editorFrame = NSRect(x: 0, y: currentInsideY, width: contentWidth, height: editorH)
                if animated { queuedEditorView.animator().frame = editorFrame } else { queuedEditorView.frame = editorFrame }
                queuedEditorView.applyLayout(width: contentWidth)
                queuedEditorView.isHidden = false
                userContentContainerView.isHidden = true
            } else {
                queuedEditorView.isHidden = true
                if hasContent {
                    let containerFrame = NSRect(x: 0, y: currentInsideY, width: contentWidth, height: fullTextHeight)
                    if animated {
                        userContentContainerView.animator().frame = containerFrame
                    } else {
                        userContentContainerView.frame = containerFrame
                    }

                    var subY: CGFloat = 0
                    for view in userContentViews {
                        let viewH: CGFloat
                        if let tv = view as? AgentSelectableTextView {
                            let wrapWidth = max(50, contentWidth - 6)
                            tv.textContainer?.containerSize = NSSize(width: wrapWidth, height: .greatestFiniteMagnitude)
                            viewH = measuredTextHeight(for: tv, attributedString: tv.attributedString(), width: wrapWidth)
                            let vFrame = NSRect(x: 0, y: subY, width: contentWidth, height: viewH)
                            if animated { tv.animator().frame = vFrame } else { tv.frame = vFrame }
                            tv.layer?.masksToBounds = true
                        } else if let cb = view as? AgentUserCodeBlockView {
                            viewH = cb.height(for: contentWidth)
                            let vFrame = NSRect(x: 0, y: subY, width: contentWidth, height: viewH)
                            if animated { cb.animator().frame = vFrame } else { cb.frame = vFrame }
                            cb.applyLayout(width: contentWidth)
                        } else if let qv = view as? AgentUserQuoteBlockView {
                            viewH = qv.height(for: contentWidth)
                            let vFrame = NSRect(x: 0, y: subY, width: contentWidth, height: viewH)
                            if animated { qv.animator().frame = vFrame } else { qv.frame = vFrame }
                            qv.applyLayout(width: contentWidth)
                        } else {
                            viewH = 0
                        }
                        subY += viewH + 8
                    }
                    userContentContainerView.layer?.masksToBounds = false
                    userContentContainerView.isHidden = false
                } else {
                    userContentContainerView.isHidden = true
                }
            }
        } else {
            let agentSize = AgentAvatarProvider.currentAgentAvatarSize(for: agentId)
            let maxW = AgentMessageCell.maxAvatarWidth
            let iconX = AgentMessageCell.iconLeft + (maxW - agentSize) / 2
            let minContentTop: CGFloat = (!thoughtHeaderButton.isHidden || hasCompactTopThought) ? 3 : 5
            let (avatarY, contentTop) = verticalAlignmentOffsets(
                avatarSize: agentSize,
                firstRowCenterOffset: assistantFirstRowCenterOffset(contentWidth: contentWidth),
                minContentTop: minContentTop
            )
            let roleFrame = NSRect(x: iconX, y: avatarY, width: agentSize, height: agentSize)
            let auraFrame = AgentAvatarAuraView.frame(around: roleFrame)
            if animated {
                roleIconView.animator().frame = roleFrame
                avatarAuraView.animator().frame = auraFrame
            } else {
                roleIconView.frame = roleFrame
                avatarAuraView.frame = auraFrame
            }
            stickyAvatarBaseY = roleFrame.origin.y
            if !animated { applyStickyAvatar() }

            var currentY = contentTop

            let firstViewIsTool = isToolCallView(firstVisibleAssistantView() ?? NSView())
            if !thoughtHeaderButton.isHidden {
                let thFrame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: 20)
                if animated {
                    thoughtHeaderButton.animator().frame = thFrame
                } else {
                    thoughtHeaderButton.frame = thFrame
                }
                currentY += 22
                if isThoughtExpanded && !hasInlineThoughtParts {
                    let thoughtWrapWidth = max(50, contentWidth - 10 - 6)
                    let h = measuredTextHeight(
                        for: thoughtTextView,
                        attributedString: thoughtTextView.attributedString(),
                        width: thoughtWrapWidth
                    )
                    thoughtTextView.textContainer?.containerSize = NSSize(width: thoughtWrapWidth, height: .greatestFiniteMagnitude)
                    let tvFrame = NSRect(x: contentLeft + 8, y: currentY, width: contentWidth - 10, height: h)
                    if animated {
                        thoughtTextView.animator().frame = tvFrame
                    } else {
                        thoughtTextView.frame = tvFrame
                    }
                    thoughtTextView.layer?.masksToBounds = true
                    currentY += h + (firstViewIsTool ? (isCompactMode ? 10 : 14) : 8)
                } else if firstViewIsTool {
                    currentY += isCompactMode ? 5 : 8
                }
            } else if hasCompactTopThought {
                let thoughtWrapWidth = max(50, contentWidth - 6)
                let h = measuredTextHeight(
                    for: thoughtTextView,
                    attributedString: thoughtTextView.attributedString(),
                    width: thoughtWrapWidth
                )
                thoughtTextView.textContainer?.containerSize = NSSize(width: thoughtWrapWidth, height: .greatestFiniteMagnitude)
                let tvFrame = NSRect(x: contentLeft, y: currentY, width: contentWidth, height: h)
                thoughtTextView.isHidden = false
                if animated {
                    thoughtTextView.animator().frame = tvFrame
                } else {
                    thoughtTextView.frame = tvFrame
                }
                thoughtTextView.layer?.masksToBounds = true
                currentY += h + (firstViewIsTool ? (isCompactMode ? 10 : 14) : 8)
            }

            for (index, view) in orderedAssistantViews.enumerated() {
                guard !view.isHidden, view.alphaValue > 0.01 else { continue }
                if isEditedFilesCardView(view) {
                    currentY += isCompactMode ? 6 : 8
                }
                let spacing = spacingAfterAssistantView(at: index)
                currentY += applyAssistantViewLayout(
                    view,
                    width: width,
                    currentY: currentY,
                    animated: animated,
                    spacing: spacing
                )
            }
        }

        layoutNeedsApplication = false
    }

    func isEditedFilesCardView(_ view: NSView) -> Bool {
        guard let editedFilesCardView else { return false }
        return editedFilesCardView === view
    }

    func isToolCallView(_ view: NSView) -> Bool {
        view is AgentToolCardView || view is AgentSimpleToolCallView || view is AgentToolGroupView
    }

    func firstVisibleAssistantView() -> NSView? {
        for view in orderedAssistantViews {
            if !view.isHidden && view.alphaValue > 0.01 {
                return view
            }
        }
        return nil
    }

    func nextVisibleAssistantView(after index: Int) -> NSView? {
        for nextIdx in (index + 1)..<orderedAssistantViews.count {
            let nextView = orderedAssistantViews[nextIdx]
            if !nextView.isHidden && nextView.alphaValue > 0.01 {
                return nextView
            }
        }
        return nil
    }

    func spacingAfterAssistantView(at index: Int) -> CGFloat {
        let view = orderedAssistantViews[index]
        guard !view.isHidden, view.alphaValue > 0.01 else { return 0 }

        if isToolCallView(view) {
            if let nextView = nextVisibleAssistantView(after: index) {
                if !isToolCallView(nextView) {
                    if isEditedFilesCardView(nextView) {
                        return isCompactMode ? 4 : 6
                    }
                    return isCompactMode ? 10 : 14
                }
            }
            return isCompactMode ? 2 : 6
        }

        // view is NOT a tool call view
        if let nextView = nextVisibleAssistantView(after: index) {
            if isToolCallView(nextView) {
                // Next view is the first tool call in a sequence: add extra space before it
                return isCompactMode ? 10 : 14
            }
        }

        if view is AgentThoughtBlockView {
            return 2
        }

        return 6
    }

    public func finishVisibilityAnimation() {
        finishThoughtVisibilityAnimation()
        for toolView in toolCallViews {
            (toolView as? AgentToolCardView)?.finishAnimation()
        }
    }

    public func layout(for width: CGFloat) -> CGFloat {
        let widthChanged = abs(cachedLayoutWidth - width) >= 0.5
        let h = measureHeight(for: width)
        // `layoutContent` visits every cell when the document height changes,
        // but most cells are immutable during streaming. Their cached height
        // is still needed for the stack calculation; applying every frame
        // again would remeasure and reposition all of their subviews.
        if layoutNeedsApplication || widthChanged {
            applyLayout(for: width, animated: false)
        }
        return h
    }

    func allSelectableTextViews() -> [AgentSelectableTextView] {
        if message.role == .user {
            var views: [AgentSelectableTextView] = []
            for item in userContentViews {
                if let tv = item as? AgentSelectableTextView {
                    views.append(tv)
                } else if let codeBlock = item as? AgentUserCodeBlockView {
                    views.append(codeBlock.tv)
                } else if let quoteBlock = item as? AgentUserQuoteBlockView {
                    views.append(quoteBlock.tv)
                }
            }
            return views.isEmpty ? [userTextView] : views
        }
        var views: [AgentSelectableTextView] = []
        if isThoughtExpanded || hasCompactTopThought {
            views.append(thoughtTextView)
        }
        for item in orderedAssistantViews {
            if let thought = item as? AgentThoughtBlockView {
                if thought.isExpanded {
                    views.append(thought.textView)
                }
            } else if item is AgentToolCardView || item is AgentToolGroupView {
                // Tool details use their own virtualized editor and handle
                // local selection/copy directly inside that viewport.
            } else if let tv = item as? AgentSelectableTextView {
                views.append(tv)
            } else if let codeBlock = item as? AgentCodeBlockView {
                if codeBlock.isExpanded {
                    views.append(codeBlock.tv)
                }
            } else if let codeBlock = item as? AgentUserCodeBlockView {
                views.append(codeBlock.tv)
            } else if let quoteBlock = item as? AgentUserQuoteBlockView {
                views.append(quoteBlock.tv)
            } else if item is MermaidBlockView {
                // Mermaid blocks manage their own code selection internally when switched to Code mode.
            } else if let tv = item.subviews.first(where: { $0 is AgentSelectableTextView }) as? AgentSelectableTextView {
                views.append(tv)
            } else if item.subviews.count > 1, let tv = item.subviews[1] as? AgentSelectableTextView {
                views.append(tv)
            }
        }
        return views
    }
}
