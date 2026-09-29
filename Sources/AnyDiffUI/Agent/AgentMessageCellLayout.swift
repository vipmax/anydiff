import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

extension AgentMessageCell {
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
            return measuredTextHeight(for: tv, attributedString: tv.attributedString(), width: contentWidth)
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
        let horizontalPadding: CGFloat = 16
        let contentWidth = max(50, width - (horizontalPadding * 2))
        let height = assistantViewHeight(view, contentWidth: contentWidth)

        if let thought = view as? AgentThoughtBlockView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { thought.animator().frame = frame } else { thought.frame = frame }
            thought.applyLayout(width: contentWidth, animated: animated)
        } else if let simple = view as? AgentSimpleToolCallView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { simple.animator().frame = frame } else { simple.frame = frame }
            simple.applyLayout(width: contentWidth)
        } else if let card = view as? AgentToolCardView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { card.animator().frame = frame } else { card.frame = frame }
            card.applyLayout(width: contentWidth, animated: animated)
        } else if let card = view as? AgentEditedFilesCardView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { card.animator().frame = frame } else { card.frame = frame }
            card.applyLayout(width: contentWidth)
        } else if let tv = view as? AgentSelectableTextView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: height)
            if animated { tv.animator().frame = frame } else { tv.frame = frame }
            if tv.layer?.mask != nil {
                tv.layer?.mask = nil
            }
        } else if let divider = view as? AgentDividerView {
            let frame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: 16)
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
            let blockFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: totalCodeHeight)
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
        } else if view.subviews.count >= 2 {
            let bar = view.subviews[0]
            let quoteTV = view.subviews[1] as? AgentSelectableTextView
            let qHeight = measuredTextHeight(
                for: quoteTV ?? view,
                attributedString: quoteTV?.attributedString() ?? NSAttributedString(),
                width: contentWidth - 24
            )
            let totalHeight = qHeight + 12
            let blockFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: totalHeight)
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
        if abs(cachedLayoutWidth - width) < 0.5, cachedLayoutHeight > 0 {
            return cachedLayoutHeight
        }

        let horizontalPadding: CGFloat = 16
        let contentWidth = max(50, width - (horizontalPadding * 2))
        let height: CGFloat

        if message.role == .user {
            let bubbleWidth = contentWidth
            let hasImages = !userImageViews.isEmpty
            let imagesHeight: CGFloat = hasImages ? (userImageViews.count == 1 ? 140 : 54) : 0
            let hasContent = !userContentViews.isEmpty
            let fullTextHeight = hasContent ? measureUserContentViewsHeight(width: bubbleWidth - 28) : 0
            let hasComplexViews = userContentViews.contains { $0 is AgentUserCodeBlockView || $0 is AgentUserQuoteBlockView }
            let isCollapsible = !hasComplexViews && fullTextHeight > userTextCollapseThreshold
            let displayedTextHeight = (isCollapsible && !isUserTextExpanded) ? maxUserTextCollapsedHeight : fullTextHeight
            let buttonHeight: CGFloat = isCollapsible ? 22 : 0
            let buttonSpacing: CGFloat = isCollapsible ? 4 : 0

            let bubbleHeight = 9 + imagesHeight + (hasImages && hasContent ? 8 : 0) + displayedTextHeight + (isCollapsible ? (buttonSpacing + buttonHeight) : 0) + 9
            height = bubbleHeight + 8
        } else {
            var currentY: CGFloat = 4

            let firstViewIsTool = isToolCallView(firstVisibleAssistantView() ?? NSView())
            if !thoughtHeaderButton.isHidden {
                currentY += 22
                if isThoughtExpanded && !hasInlineThoughtParts {
                    let h = measuredTextHeight(
                        for: thoughtTextView,
                        attributedString: thoughtTextView.attributedString(),
                        width: contentWidth - 10
                    )
                    currentY += h + (firstViewIsTool ? 14 : 8)
                } else if firstViewIsTool {
                    currentY += 8
                }
            } else if hasCompactTopThought {
                let h = measuredTextHeight(
                    for: thoughtTextView,
                    attributedString: thoughtTextView.attributedString(),
                    width: contentWidth
                )
                currentY += h + (firstViewIsTool ? 14 : 8)
            }

            for (index, view) in orderedAssistantViews.enumerated() {
                guard !view.isHidden, view.alphaValue > 0.01 else { continue }
                if isEditedFilesCardView(view) {
                    currentY += 8
                }
                let spacing = spacingAfterAssistantView(at: index)
                currentY += assistantViewHeight(view, contentWidth: contentWidth) + spacing
            }

            height = currentY + 4
        }

        cachedLayoutWidth = width
        cachedLayoutHeight = height
        return height
    }

    public func applyLayout(for width: CGFloat, animated: Bool) {
        let horizontalPadding: CGFloat = 16
        let contentWidth = max(50, width - (horizontalPadding * 2))

        if message.role == .user {
            let bubbleWidth = contentWidth
            let hasImages = !userImageViews.isEmpty
            let imagesHeight: CGFloat = hasImages ? (userImageViews.count == 1 ? 140 : 54) : 0
            let hasContent = !userContentViews.isEmpty
            let fullTextHeight = hasContent ? measureUserContentViewsHeight(width: bubbleWidth - 28) : 0

            let hasComplexViews = userContentViews.contains { $0 is AgentUserCodeBlockView || $0 is AgentUserQuoteBlockView }
            let isCollapsible = !hasComplexViews && fullTextHeight > userTextCollapseThreshold
            let displayedTextHeight = (isCollapsible && !isUserTextExpanded) ? maxUserTextCollapsedHeight : fullTextHeight
            let buttonHeight: CGFloat = isCollapsible ? 22 : 0
            let buttonSpacing: CGFloat = isCollapsible ? 4 : 0

            let bubbleHeight = 9 + imagesHeight + (hasImages && hasContent ? 8 : 0) + displayedTextHeight + (isCollapsible ? (buttonSpacing + buttonHeight) : 0) + 9

            let bubbleFrame = NSRect(
                x: horizontalPadding,
                y: 4,
                width: bubbleWidth,
                height: bubbleHeight
            )
            if animated {
                userBubbleView.animator().frame = bubbleFrame
            } else {
                userBubbleView.frame = bubbleFrame
            }
            let bubbleBounds = CGRect(origin: .zero, size: bubbleFrame.size)
            userBubbleView.layer?.shadowPath = CGPath(
                roundedRect: bubbleBounds,
                cornerWidth: 13,
                cornerHeight: 13,
                transform: nil
            )

            var currentInsideY: CGFloat = 9
            if hasImages {
                if userImageViews.count == 1, let singleBtn = userImageViews.first {
                    let imgW = min(bubbleWidth - 28, 180)
                    let imgFrame = NSRect(x: 14, y: currentInsideY, width: imgW, height: 140)
                    if animated { singleBtn.animator().frame = imgFrame } else { singleBtn.frame = imgFrame }
                } else {
                    for (i, btn) in userImageViews.enumerated() {
                        let btnFrame = NSRect(x: 14 + CGFloat(i) * 60, y: currentInsideY, width: 54, height: 54)
                        if animated { btn.animator().frame = btnFrame } else { btn.frame = btnFrame }
                    }
                }
                currentInsideY += imagesHeight + (hasContent ? 8 : 0)
            }

            userTextView.isHidden = true

            if hasContent {
                let contentW = bubbleWidth - 28
                let containerFrame = NSRect(x: 14, y: currentInsideY, width: contentW, height: displayedTextHeight)
                if animated {
                    userContentContainerView.animator().frame = containerFrame
                } else {
                    userContentContainerView.frame = containerFrame
                }

                var subY: CGFloat = 0
                for view in userContentViews {
                    let viewH: CGFloat
                    if let tv = view as? AgentSelectableTextView {
                        viewH = measuredTextHeight(for: tv, attributedString: tv.attributedString(), width: contentW)
                        let vFrame = NSRect(x: 0, y: subY, width: contentW, height: viewH)
                        if animated { tv.animator().frame = vFrame } else { tv.frame = vFrame }
                    } else if let cb = view as? AgentUserCodeBlockView {
                        viewH = cb.height(for: contentW)
                        let vFrame = NSRect(x: 0, y: subY, width: contentW, height: viewH)
                        if animated { cb.animator().frame = vFrame } else { cb.frame = vFrame }
                        cb.applyLayout(width: contentW)
                    } else if let qv = view as? AgentUserQuoteBlockView {
                        viewH = qv.height(for: contentW)
                        let vFrame = NSRect(x: 0, y: subY, width: contentW, height: viewH)
                        if animated { qv.animator().frame = vFrame } else { qv.frame = vFrame }
                        qv.applyLayout(width: contentW)
                    } else {
                        viewH = 0
                    }
                    subY += viewH + 8
                }
                userContentContainerView.isHidden = false

                if isCollapsible {
                    userExpandButton.isHidden = false
                    updateUserExpandButtonAppearance()

                    let btnWidth: CGFloat = 92
                    let btnFrame = NSRect(
                        x: 14,
                        y: currentInsideY + displayedTextHeight + buttonSpacing,
                        width: btnWidth,
                        height: buttonHeight
                    )
                    if animated {
                        userExpandButton.animator().frame = btnFrame
                    } else {
                        userExpandButton.frame = btnFrame
                    }
                } else {
                    userExpandButton.isHidden = true
                }
            } else {
                userContentContainerView.isHidden = true
                userExpandButton.isHidden = true
            }
        } else {
            var currentY: CGFloat = 4

            let firstViewIsTool = isToolCallView(firstVisibleAssistantView() ?? NSView())
            if !thoughtHeaderButton.isHidden {
                let thFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: 20)
                if animated {
                    thoughtHeaderButton.animator().frame = thFrame
                } else {
                    thoughtHeaderButton.frame = thFrame
                }
                currentY += 22
                if isThoughtExpanded && !hasInlineThoughtParts {
                    let h = measuredTextHeight(
                        for: thoughtTextView,
                        attributedString: thoughtTextView.attributedString(),
                        width: contentWidth - 10
                    )
                    let tvFrame = NSRect(x: horizontalPadding + 8, y: currentY, width: contentWidth - 10, height: h)
                    if animated {
                        thoughtTextView.animator().frame = tvFrame
                    } else {
                        thoughtTextView.frame = tvFrame
                    }
                    currentY += h + (firstViewIsTool ? 14 : 8)
                } else if firstViewIsTool {
                    currentY += 8
                }
            } else if hasCompactTopThought {
                let h = measuredTextHeight(
                    for: thoughtTextView,
                    attributedString: thoughtTextView.attributedString(),
                    width: contentWidth
                )
                let tvFrame = NSRect(x: horizontalPadding, y: currentY, width: contentWidth, height: h)
                thoughtTextView.isHidden = false
                if animated {
                    thoughtTextView.animator().frame = tvFrame
                } else {
                    thoughtTextView.frame = tvFrame
                }
                currentY += h + (firstViewIsTool ? 14 : 8)
            }

            for (index, view) in orderedAssistantViews.enumerated() {
                guard !view.isHidden, view.alphaValue > 0.01 else { continue }
                if isEditedFilesCardView(view) {
                    currentY += 8
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
        view is AgentToolCardView || view is AgentSimpleToolCallView
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
                        return 6
                    }
                    return 14
                }
            }
            return 6
        }

        // view is NOT a tool call view
        if let nextView = nextVisibleAssistantView(after: index) {
            if isToolCallView(nextView) {
                // Next view is the first tool call in a sequence: add extra space before it
                return 14
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
            } else if item is AgentToolCardView {
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
            } else if let tv = item.subviews.first(where: { $0 is AgentSelectableTextView }) as? AgentSelectableTextView {
                views.append(tv)
            } else if item.subviews.count > 1, let tv = item.subviews[1] as? AgentSelectableTextView {
                views.append(tv)
            }
        }
        return views
    }
}

