import SwiftUI
import AppKit
import QuartzCore
import AnyDiffCore

public final class AgentEditedFileRowView: AgentFlippedView {
    private let filenameLabel = AgentStaticTextField(labelWithString: "")
    private let directoryLabel = AgentStaticTextField(labelWithString: "")
    private let statsLabel = AgentStaticTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(filenameLabel)
        addSubview(directoryLabel)
        addSubview(statsLabel)
        filenameLabel.lineBreakMode = .byClipping
        directoryLabel.lineBreakMode = .byTruncatingMiddle
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(file: AgentEditedFileItem, theme: Theme) {
        filenameLabel.attributedStringValue = NSAttributedString(
            string: file.filename,
            attributes: [
                .foregroundColor: theme.foreground,
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
            ]
        )

        let dirString = file.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !dirString.isEmpty {
            directoryLabel.isHidden = false
            directoryLabel.attributedStringValue = NSAttributedString(
                string: dirString,
                attributes: [
                    .foregroundColor: theme.gutterForeground.withAlphaComponent(0.85),
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
                ]
            )
        } else {
            directoryLabel.isHidden = true
            directoryLabel.stringValue = ""
        }

        let statsAttr = NSMutableAttributedString()
        if file.additions > 0 {
            statsAttr.append(NSAttributedString(
                string: "+\(file.additions)",
                attributes: [
                    .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.95),
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
                ]
            ))
        }
        if file.deletions > 0 {
            if file.additions > 0 {
                statsAttr.append(NSAttributedString(
                    string: " ",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
                    ]
                ))
            }
            statsAttr.append(NSAttributedString(
                string: "-\(file.deletions)",
                attributes: [
                    .foregroundColor: NSColor.systemRed.withAlphaComponent(0.95),
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)
                ]
            ))
        }
        statsLabel.attributedStringValue = statsAttr
    }

    public func applyLayout(width: CGFloat) {
        let statsSize = statsLabel.sizeThatFits(NSSize(width: 120, height: 18))
        let statsWidth = statsSize.width
        statsLabel.frame = NSRect(x: max(0, width - statsWidth), y: 0, width: statsWidth, height: 18)

        let availableTextWidth = max(0, width - statsWidth - 8)
        let nameSize = filenameLabel.sizeThatFits(NSSize(width: availableTextWidth, height: 18))
        let nameWidth = min(availableTextWidth, nameSize.width)
        filenameLabel.frame = NSRect(x: 0, y: 0, width: nameWidth, height: 18)

        if !directoryLabel.isHidden {
            let dirX = nameWidth + 8
            let dirWidth = max(0, availableTextWidth - dirX)
            directoryLabel.frame = NSRect(x: dirX, y: 0, width: dirWidth, height: 18)
        }
    }
}

public final class AgentEditedFilesCardView: AgentFlippedView {
    public private(set) var summary: AgentEditedFilesSummary
    private var theme: Theme
    private var accentColor: Color
    private var disableAgentColors: Bool
    public var onReview: ((AgentEditedFilesSummary) -> Void)?
    public var onRevert: ((AgentEditedFilesSummary) -> Void)?
    public var onRestore: ((AgentEditedFilesSummary) -> Void)?

    private let titleLabel = AgentStaticTextField(labelWithString: "")
    private let statsLabel = AgentStaticTextField(labelWithString: "")
    private let restoreButton = AgentHoverButton(frame: .zero)
    private let revertButton = AgentHoverButton(frame: .zero)
    private let reviewButton = AgentHoverButton(frame: .zero)
    private let divider = NSBox()
    private var fileRowViews: [AgentEditedFileRowView] = []

    public init(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        accentColor: Color = .accentColor,
        disableAgentColors: Bool = false
    ) {
        self.summary = summary
        self.theme = theme
        self.accentColor = accentColor
        self.disableAgentColors = disableAgentColors
        super.init(frame: .zero)
        setup()
        configure(summary: summary, theme: theme, accentColor: accentColor, disableAgentColors: disableAgentColors)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(titleLabel)

        statsLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .bold)
        addSubview(statsLabel)

        restoreButton.target = self
        restoreButton.action = #selector(handleRestoreClicked)
        addSubview(restoreButton)

        revertButton.target = self
        revertButton.action = #selector(handleRevertClicked)
        addSubview(revertButton)

        reviewButton.target = self
        reviewButton.action = #selector(handleReviewClicked)
        addSubview(reviewButton)

        divider.boxType = .separator
        addSubview(divider)
    }

    @objc private func handleRestoreClicked() {
        onRestore?(summary)
    }

    @objc private func handleRevertClicked() {
        onRevert?(summary)
    }

    @objc private func handleReviewClicked() {
        onReview?(summary)
    }

    public func configure(
        summary: AgentEditedFilesSummary,
        theme: Theme,
        accentColor: Color,
        disableAgentColors: Bool
    ) {
        self.summary = summary
        self.theme = theme
        self.accentColor = accentColor
        self.disableAgentColors = disableAgentColors

        let nsAccent = NSColor(accentColor)
        let fgColor = summary.isReverted ? theme.gutterForeground : theme.foreground
        titleLabel.textColor = fgColor
        titleLabel.stringValue = summary.displayTitle

        layer?.backgroundColor = nsAccent.withAlphaComponent(0.08).cgColor
        layer?.borderColor = nsAccent.withAlphaComponent(0.18).cgColor

        if summary.isReverted {
            restoreButton.isHidden = false
            revertButton.isHidden = true
            reviewButton.isHidden = true
            statsLabel.isHidden = true

            restoreButton.imagePosition = .noImage
            restoreButton.image = nil
            restoreButton.contentTintColor = NSColor.systemBlue
            restoreButton.defaultBackgroundColor = NSColor.white.withAlphaComponent(0.06)
            restoreButton.hoverBackgroundColor = NSColor.systemBlue.withAlphaComponent(0.20)
            restoreButton.attributedTitle = NSAttributedString(
                string: "Redo",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.systemBlue
                ]
            )
        } else {
            restoreButton.isHidden = true
            revertButton.isHidden = false
            reviewButton.isHidden = false
            statsLabel.isHidden = false

            revertButton.imagePosition = .noImage
            revertButton.image = nil
            revertButton.contentTintColor = NSColor.systemRed.withAlphaComponent(0.9)
            revertButton.defaultBackgroundColor = NSColor.white.withAlphaComponent(0.06)
            revertButton.hoverBackgroundColor = NSColor.systemRed.withAlphaComponent(0.20)
            revertButton.attributedTitle = NSAttributedString(
                string: "Undo",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.systemRed.withAlphaComponent(0.9)
                ]
            )

            reviewButton.imagePosition = .noImage
            reviewButton.image = nil
            reviewButton.contentTintColor = fgColor
            reviewButton.defaultBackgroundColor = NSColor.white.withAlphaComponent(0.06)
            reviewButton.hoverBackgroundColor = NSColor.white.withAlphaComponent(0.15)
            reviewButton.attributedTitle = NSAttributedString(
                string: "Review",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: fgColor.withAlphaComponent(0.95)
                ]
            )

            let statsAttr = NSMutableAttributedString()
            if summary.totalAdditions > 0 {
                statsAttr.append(NSAttributedString(
                    string: "+\(summary.totalAdditions)",
                    attributes: [.foregroundColor: NSColor.systemGreen.withAlphaComponent(0.95), .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)]
                ))
            }
            if summary.totalDeletions > 0 {
                if summary.totalAdditions > 0 {
                    statsAttr.append(NSAttributedString(
                        string: " ",
                        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)]
                    ))
                }
                statsAttr.append(NSAttributedString(
                    string: "-\(summary.totalDeletions)",
                    attributes: [.foregroundColor: NSColor.systemRed.withAlphaComponent(0.95), .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)]
                ))
            }
            statsLabel.attributedStringValue = statsAttr
        }

        while fileRowViews.count < summary.files.count {
            let row = AgentEditedFileRowView()
            addSubview(row)
            fileRowViews.append(row)
        }
        while fileRowViews.count > summary.files.count {
            let row = fileRowViews.removeLast()
            row.removeFromSuperview()
        }

        for (index, file) in summary.files.enumerated() {
            fileRowViews[index].configure(file: file, theme: theme)
        }
    }

    public func measureHeight(width: CGFloat) -> CGFloat {
        let headerHeight: CGFloat = 26
        let dividerHeight: CGFloat = 6
        let fileRowsHeight: CGFloat = CGFloat(summary.files.count) * 20
        return 10 + headerHeight + dividerHeight + fileRowsHeight + 8
    }

    public func applyLayout(width: CGFloat) {
        let padding: CGFloat = 10
        let contentWidth = max(50, width - (padding * 2))
        var currentY: CGFloat = padding

        let titleSize = titleLabel.sizeThatFits(NSSize(width: contentWidth * 0.5, height: 22))
        titleLabel.frame = NSRect(x: padding, y: currentY + 1, width: titleSize.width, height: 20)

        var rightX = width - padding

        if !summary.isReverted {
            if summary.totalAdditions > 0 || summary.totalDeletions > 0 {
                let statsSize = statsLabel.sizeThatFits(NSSize(width: 120, height: 20))
                let statsWidth = statsSize.width
                statsLabel.frame = NSRect(x: width - padding - statsWidth, y: currentY + 1, width: statsWidth, height: 20)
                rightX -= (statsWidth + 10)
            }

            let reviewWidth: CGFloat = 58
            rightX -= reviewWidth
            reviewButton.frame = NSRect(x: rightX, y: currentY, width: reviewWidth, height: 22)
            rightX -= 6

            let revertWidth: CGFloat = 52
            rightX -= revertWidth
            revertButton.frame = NSRect(x: rightX, y: currentY, width: revertWidth, height: 22)
        } else {
            let restoreWidth: CGFloat = 52
            rightX -= restoreWidth
            restoreButton.frame = NSRect(x: rightX, y: currentY, width: restoreWidth, height: 22)
        }

        currentY += 26

        divider.frame = NSRect(x: padding, y: currentY, width: contentWidth, height: 1)
        currentY += 5

        for row in fileRowViews {
            row.frame = NSRect(x: padding, y: currentY, width: contentWidth, height: 18)
            row.applyLayout(width: contentWidth)
            currentY += 20
        }
    }
}
