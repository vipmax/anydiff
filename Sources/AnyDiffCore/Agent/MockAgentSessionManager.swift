import Foundation

public final class MockAgentSessionManager: AgentSessionManager, @unchecked Sendable {
    public override var isMock: Bool { true }
    private var mockTask: Task<Void, Never>? = nil

    public init(loadFixtures: Bool = true) {
        super.init()
        self.agentTitle = "Mock Agent"
        self.configOptions = [
            ACPConfigOption(
                id: ACPConfigOptionID.model,
                name: "Model",
                category: "model",
                type: "select",
                currentValue: "mock-pro",
                options: [
                    ACPConfigOption.OptionValue(value: "mock-pro", name: "Mock Model (Pro)"),
                    ACPConfigOption.OptionValue(value: "mock-fast", name: "Mock Model (Fast)")
                ]
            )
        ]
        self.selectedModel = "Mock Model (Pro)"
        self.selectedModelValue = "mock-pro"
        self.contextUsagePercentage = 72
        self.status = .idle
        self.initializationState = .ready
        if loadFixtures {
            self.loadSampleConversation()
        }
    }

    public func loadSampleConversation() {
        let msg1 = AgentMessage(
            role: .user,
            content: "Hello! What can AnyDiff do and what is its main feature?"
        )

        let msg2 = AgentMessage(
            role: .assistant,
            content: """
            Hello! 🚀 **AnyDiff** is a native, ultra-fast macOS Git/Diff client built in Swift with zero external dependencies.

            ### ✨ Key Features:
            - **Side-by-Side & Unified Diff**: Intra-line word-level change highlighting.
            - **Virtualized MultiBuffer Editor**: Smooth scrolling across millions of lines with zero lag.
            - **Direct Working Tree Editing**: Edit working copies directly in the comparison view with real-time Myers diff recalculation.
            - **Built-in Agent Mode (ACP)**: Contextual AI assistant with filesystem and terminal tool support.
            """,
            thought: "Generating an overview of AnyDiff features for the user.",
            toolCalls: [
                ToolCallItem(
                    toolName: "view_file",
                    path: "AGENTS.md",
                    descriptionText: "Read repository guidelines and architecture rules",
                    startLine: 1,
                    endLine: 65,
                    status: .completed
                )
            ],
            isStreaming: false
        )

        let msg3 = AgentMessage(
            role: .user,
            content: "How does MultiBuffer virtualization work?"
        )

        let msg4 = AgentMessage(
            role: .assistant,
            content: """
            In AnyDiff, virtualization is built around a three-tier model:

            1. **Coordinate Grid**: Continuous line array with lazy context unfolding around modified hunks.
            2. **Viewport Culling**: Only lines falling within the visible screen area `[firstVisibleLine, lastVisibleLine]` + 10 overscan lines are rendered.
            3. **Zero-Copy Hunks**: Unchanged file slices are read without heap allocations.

            ```swift
            // Example visible line calculation
            let startLine = max(0, Int(scrollOffset / lineHeight) - overscan)
            let endLine = min(totalLines, startLine + visibleLineCount + overscan * 2)
            ```
            """,
            thought: "Reviewing AnyDiffCore/MultiBuffer architecture and virtualized EditorHostView.",
            toolCalls: [
                ToolCallItem(
                    toolName: "view_file",
                    path: "Sources/AnyDiffCore/MultiBuffer/MultiBuffer.swift",
                    descriptionText: "Inspect coordinate mapping and viewport culling",
                    startLine: 120,
                    endLine: 240,
                    status: .completed
                )
            ],
            isStreaming: false
        )

        let msg5 = AgentMessage(
            role: .user,
            content: "Run tests and verify stability"
        )

        let msg6 = AgentMessage(
            role: .assistant,
            content: """
            All tests and benchmarks passed successfully! ⚡️

            - **Unit Tests**: 79 passed (0 failures) in `0.68s`
            - **Myers Diff Throughput**: `~1.2ms` on 10,000 lines with common prefix/suffix pruning.
            - **Memory Packing**: 0 memory leaks.

            ```
            ✔ Test Suite 'Selected tests' passed (79 tests in 0.685s)
            ✔ Benchmark 'MyersDiffPruning' took 0.0012s (10k lines)
            ```

            > 💡 The Myers algorithm is optimized with $O(ND)$ complexity and fast boundary pruning.
            """,
            thought: "Running test runner via ACP terminal/create and analyzing XCTest output.",
            toolCalls: [
                ToolCallItem(
                    toolName: "run_command",
                    descriptionText: "Run AnyDiff unit and regression tests",
                    command: "swift test -c debug --filter AnyDiffCoreTests",
                    output: "Test Suite 'Selected tests' passed (79 tests in 0.685s)\nBenchmark 'MyersDiffPruning' took 0.0012s (10k lines)\nAll 79 tests passed.",
                    status: .completed
                )
            ],
            isStreaming: false
        )

        let msg7 = AgentMessage(
            role: .user,
            content: "Show diff for adding Cmd+Opt+A shortcut"
        )

        let msg8 = AgentMessage(
            role: .assistant,
            content: """
            Here is the diff adding the menu item in `AppDelegate+Menu.swift`:

            ```diff
            + let agentItem = NSMenuItem(
            +     title: "Toggle Agent Panel",
            +     action: #selector(toggleAgentPanel),
            +     keyEquivalent: "a"
            + )
            + agentItem.keyEquivalentModifierMask = [.command, .option]
            + viewMenu.addItem(agentItem)
            ```

            The file has been updated and compiled.
            """,
            thought: "Drafting menu update in AppDelegate+Menu.swift.",
            toolCalls: [
                ToolCallItem(
                    toolName: "replace_file_content",
                    path: "Sources/AnyDiff/AppDelegate+Menu.swift",
                    descriptionText: "Add Toggle Agent Panel menu item with Cmd+Option+A key equivalent",
                    startLine: 63,
                    endLine: 67,
                    oldContent: "        viewMenu.addItem(NSMenuItem.separator())\n        windowMenu.addItem(NSMenuItem.separator())",
                    newContent: "        let agentItem = NSMenuItem(title: \"Toggle Agent Panel\", action: #selector(toggleAgentPanel), keyEquivalent: \"a\")\n        agentItem.keyEquivalentModifierMask = [.command, .option]\n        viewMenu.addItem(agentItem)",
                    status: .completed
                )
            ],
            editedFilesSummary: AgentEditedFilesSummary(files: [
                AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentInputView.swift", additions: 7, deletions: 4),
                AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift", additions: 14, deletions: 10),
                AgentEditedFileItem(path: "Sources/AnyDiffUI/Views/MainWindowView.swift", additions: 2, deletions: 1)
            ]),
            isStreaming: false
        )

        let msg9 = AgentMessage(
            role: .user,
            content: "How are git diff hunk headers parsed?"
        )

        let msg10 = AgentMessage(
            role: .assistant,
            content: """
            A hunk header has the format: `@@ -start,len +start,len @@ [context]`.

            `DiffParser.swift` parses it in a single pass without regular expressions:
            - `-l,s`: line range in the old file (left side).
            - `+l,s`: line range in the new file (right side).
            - If length `s` is omitted, it defaults to `1`.
            """,
            thought: "Analyzing DiffParser.swift hunk parser.",
            toolCalls: [
                ToolCallItem(
                    toolName: "fs/read_text_file",
                    path: "Sources/AnyDiffCore/Diff/DiffParser.swift",
                    summary: "Parsed hunk headers",
                    status: .completed
                )
            ],
            isStreaming: false
        )

        let msg11 = AgentMessage(
            role: .user,
            content: "Demonstrate a heavy multi-card scenario"
        )

        let msg12 = AgentMessage(
            role: .assistant,
            content: makeStressResponse(prompt: "Heavy mock scenario demonstration"),
            thought: "Assembling a large multi-block response and cross-referencing tool results.",
            toolCalls: makeStressToolCalls(),
            isStreaming: false
        )

        let sampleImageData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
            0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        let sampleImages = [
            AgentImageAttachment(data: sampleImageData, mimeType: "image/png", filename: "screenshot_diff.png", width: 1280, height: 800),
            AgentImageAttachment(data: sampleImageData, mimeType: "image/png", filename: "layout_preview.png", width: 640, height: 480)
        ]

        let msg13 = AgentMessage(
            role: .user,
            content: "Check this interface screenshot — does everything look in place?",
            images: sampleImages
        )

        let msg14 = AgentMessage(
            role: .assistant,
            content: makeImageAnalysisResponse(prompt: "Check this interface screenshot — does everything look in place?", images: sampleImages),
            thought: "Analyzing attached images...\nDetecting UI structure, typography, and diff elements.",
            toolCalls: [
                ToolCallItem(
                    toolName: "vision/inspect_image",
                    path: "screenshot_diff.png",
                    descriptionText: "Inspect visual UI layout, typography, and diff elements in screenshot",
                    summary: "Analyzed 2 image(s) successfully (resolved UI components, contrast, and layout bounds)",
                    status: .completed
                )
            ],
            isStreaming: false
        )

        self.messages = [msg1, msg2, msg3, msg4, msg5, msg6, msg7, msg8, msg9, msg10, msg11, msg12, msg13, msg14]
        self.contextUsagePercentage = 72
        self.status = .idle
        self.statusMessage = nil
    }

    public override func sendPrompt(_ text: String, images: [AgentImageAttachment] = [], workingDirectory: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }

        let userMsg = AgentMessage(role: .user, content: trimmed, images: images)
        messages.append(userMsg)

        let assistantMsgId = UUID()
        let assistantMsg = AgentMessage(id: assistantMsgId, role: .assistant, content: "", isStreaming: true)
        messages.append(assistantMsg)

        status = .busy
        statusMessage = "Thinking..."

        mockTask?.cancel()
        mockTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let idx = self.messages.firstIndex(where: { $0.id == assistantMsgId }) else { return }

            // 1. Thinking phase
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }

            let hasImages = !images.isEmpty
            let isEditRequest = trimmed.lowercased().contains("edit") || trimmed.lowercased().contains("fix") || trimmed.lowercased().contains("change")

            if hasImages {
                self.messages[idx].thought = "Analyzing \(images.count) attached image(s)...\nDetecting UI layout structure, typography, and diff elements."

                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }

                self.messages[idx].setToolCalls([
                    ToolCallItem(
                        toolName: "vision/inspect_image",
                        path: images.first?.filename ?? "screenshot.png",
                        descriptionText: "Inspect visual UI layout, typography, and diff elements in screenshot",
                        status: .running
                    )
                ])

                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { return }

                self.messages[idx].setToolCalls([
                    ToolCallItem(
                        toolName: "vision/inspect_image",
                        path: images.first?.filename ?? "screenshot.png",
                        descriptionText: "Inspect visual UI layout, typography, and diff elements in screenshot",
                        summary: "Analyzed \(images.count) image(s) successfully (resolved UI components, contrast, and layout bounds)",
                        status: .completed
                    )
                ])

                guard await self.streamResponse(
                    self.makeImageAnalysisResponse(prompt: trimmed, images: images),
                    messageId: assistantMsgId
                ) else { return }
            } else if isEditRequest {
                self.messages[idx].thought = "Analyzing AppDelegate+Menu.swift and drafting edit for agent panel menu item."

                // Step 1: Tool starts running (Live loading spinner visible, no +/- yet)
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }

                self.messages[idx].setToolCalls([
                    ToolCallItem(
                        toolName: "replace_file_content",
                        path: "Sources/AnyDiff/AppDelegate+Menu.swift",
                        descriptionText: "Add Toggle Agent Panel menu item with Cmd+Option+A key equivalent",
                        startLine: 63,
                        endLine: 67,
                        status: .running
                    )
                ])

                // Show spinner for 1.4 seconds
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if Task.isCancelled { return }

                // Step 2: Tool completes
                self.messages[idx].setToolCalls([
                    ToolCallItem(
                        toolName: "replace_file_content",
                        path: "Sources/AnyDiff/AppDelegate+Menu.swift",
                        descriptionText: "Add Toggle Agent Panel menu item with Cmd+Option+A key equivalent",
                        startLine: 63,
                        endLine: 67,
                        oldContent: "        viewMenu.addItem(NSMenuItem.separator())\n        windowMenu.addItem(NSMenuItem.separator())",
                        newContent: "        let agentItem = NSMenuItem(\n            title: \"Toggle Agent Panel\",\n            action: #selector(toggleAgentPanel),\n            keyEquivalent: \"a\"\n        )\n        agentItem.keyEquivalentModifierMask = [.command, .option]\n        viewMenu.addItem(agentItem)",
                        status: .completed
                    )
                ])

                // Live changes pill appears during streaming!
                self.liveEditedSummary = AgentEditedFilesSummary(files: [
                    AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentInputView.swift", additions: 7, deletions: 4),
                    AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift", additions: 14, deletions: 10)
                ])

                // Step 3: Keep several realistic tool cards around while a
                // large markdown response streams into the same message.
                self.messages[idx].setToolCalls(self.makeStressToolCalls())

                // Simulate new file change arriving during live streaming (appending to live summary)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard let self, self.status == .busy else { return }
                    self.liveEditedSummary = AgentEditedFilesSummary(files: [
                        AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentInputView.swift", additions: 7, deletions: 4),
                        AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift", additions: 14, deletions: 10),
                        AgentEditedFileItem(path: "Sources/AnyDiffUI/Views/MainWindowView.swift", additions: 2, deletions: 1)
                    ])
                }

                guard await self.streamResponse(
                    self.makeStressResponse(prompt: "Edit request for «\(trimmed)»"),
                    messageId: assistantMsgId
                ) else { return }
            } else {
                self.messages[idx].thought = "Analyzing prompt «\(trimmed)»...\nChecking change context and file structure."

                // 2. Simulated read tool execution
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                self.messages[idx].setToolCalls([
                    ToolCallItem(
                        toolName: "fs/read_text_file",
                        path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift",
                        descriptionText: "Inspecting UI layout",
                        status: .running
                    )
                ])

                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { return }
                self.messages[idx].setToolCalls([
                    ToolCallItem(
                        toolName: "fs/read_text_file",
                        path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift",
                        descriptionText: "Inspecting UI layout",
                        summary: "Read 180 lines successfully",
                        status: .completed
                    )
                ])

                // The default path also exercises a mixed tool timeline and
                // not just a single tiny read card.
                self.messages[idx].setToolCalls(self.makeStressToolCalls())

                // 3. Stream in medium-sized chunks.
                guard await self.streamResponse(
                    self.makeStressResponse(prompt: trimmed),
                    messageId: assistantMsgId
                ) else { return }
            }

            if isEditRequest {
                self.messages[idx].editedFilesSummary = AgentEditedFilesSummary(files: [
                    AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentInputView.swift", additions: 7, deletions: 4),
                    AgentEditedFileItem(path: "Sources/AnyDiffUI/Agent/AgentPanelView.swift", additions: 14, deletions: 10),
                    AgentEditedFileItem(path: "Sources/AnyDiffUI/Views/MainWindowView.swift", additions: 2, deletions: 1)
                ])
            }

            self.liveEditedSummary = nil
            self.messages[idx].isStreaming = false
            self.status = .idle
            self.statusMessage = nil
            self.contextUsagePercentage = min(95, (self.contextUsagePercentage ?? 68) + 4)
        }
    }

    private func streamResponse(_ response: String, messageId: UUID) async -> Bool {
        let chunks = responseChunks(response, maxCharacters: 240)
        for chunk in chunks {
            do {
                try await Task.sleep(nanoseconds: 45_000_000)
            } catch {
                return false
            }
            guard !Task.isCancelled, let idx = messages.firstIndex(where: { $0.id == messageId }) else {
                return false
            }
            messages[idx].appendText(chunk)
        }
        return true
    }

    private func responseChunks(_ response: String, maxCharacters: Int) -> [String] {
        guard !response.isEmpty else { return [] }

        var chunks: [String] = []
        var start = response.startIndex
        while start < response.endIndex {
            let distance = response.distance(from: start, to: response.endIndex)
            let offset = min(maxCharacters, distance)
            let end = response.index(start, offsetBy: offset)
            chunks.append(String(response[start..<end]))
            start = end
        }
        return chunks
    }

    private func makeImageAnalysisResponse(prompt: String, images: [AgentImageAttachment]) -> String {
        let details = images.enumerated().map { index, img in
            let name = img.filename ?? "image_\(index + 1).png"
            let dims: String
            if let w = img.width, let h = img.height {
                dims = " (\(Int(w))×\(Int(h)) px)"
            } else {
                dims = ""
            }
            return "- **Image \(index + 1)**: `\(name)`\(dims) · `\(img.mimeType)` · `\(img.fileSizeDescription)`"
        }.joined(separator: "\n")

        let promptSection = prompt.isEmpty ? "" : "\n\n> 💬 **User Request**: «\(prompt)»"

        return """
        # 🖼️ Visual Inspection Report

        I have analyzed the attached image(s) (\(images.count)):

        \(details)\(promptSection)

        ### 🔍 Key Observations:
        1. **UI Components**: The screenshot displays AnyDiff workspace elements (MultiBuffer, diff comparison views, and side panel).
        2. **Thumbnails & Preview**: Attachment preview cards are rendered with continuous corner radiuses and hover states.
        3. **Color Scheme & Contrast**: Typography and contrast conform to the active theme palette.

        ```swift
        // Detected metadata summary
        struct VisualInspectionResult {
            let imageCount: Int = \(images.count)
            let isDiffVisible: Bool = true
            let suggestedAction: String = "Ready to apply code changes or inspect further details."
        }
        ```

        If you would like to apply any code modifications based on these images, let me know and I will generate the patch! 🚀
        """
    }

    private func makeStressResponse(prompt: String) -> String {
        let diagnostics = (1...42).map { index in
            "- `event_\(String(format: "%03d", index))`: layout pass \((index % 7) + 1), measured \(118 + index) nodes, cache hit \(index % 4 != 0 ? "yes" : "no")"
        }.joined(separator: "\n")

        let code = (1...72).map { index in
            "    let result_\(index) = await pipeline.stage(\(index), width: viewportWidth, cache: layoutCache)"
        }.joined(separator: "\n")

        return """
        # Request Breakdown

        Request: `\(prompt)`

        Done. I ran the scenario through multiple tools and assembled a comprehensive response to test the panel under realistic load. Below are structured text sections, lists, quotes, shell outputs, and a large Swift code block.

        ## Verified Items

        - Layout stability during panel resize gestures.
        - Scroll anchor retention when scrolled up from the bottom.
        - Multiple tool calls with distinct statuses and expandable details.
        - Large responses without recreating pre-existing rendered cells.
        - Transition between streaming and syntax-highlighted code blocks.

        ### Layout Diagnostics

        \(diagnostics)

        > Note: Tool outputs are measured lazily to maintain low memory overhead during rendering.

        ```swift
        struct StreamingLayoutCoordinator {
            var viewportWidth: CGFloat
            var layoutCache: [UUID: CGFloat] = [:]

            mutating func updateVisibleMessages(_ messages: [AgentMessage]) async {
                for message in messages where message.role == .assistant {
                    let key = message.id
                    layoutCache[key] = await measure(message, width: viewportWidth)
                }
            }

        \(code)
        }
        ```

        ## Summary

        For smooth streaming performance, text tokens are delivered in balanced chunks with debounced layout measurements and zero implicit animations on incremental updates.
        """
    }

    private func makeStressToolCalls() -> [ToolCallItem] {
        let commandOutput = (1...180).map { index in
            "[\(String(format: "%04d", index))] layout.measure(message: \(index), width: \(420 + index % 80)) -> height=\(42 + index % 31) cache=\(index % 5 == 0 ? "miss" : "hit")"
        }.joined(separator: "\n")

        // Large edit fixture for exercising the virtualized tool detail view.
        let oldLines = (1...100).map { index in
            "    let previousHeight_\(index) = measure(message, width: width - \(index % 6))"
        }.joined(separator: "\n")
        let newLines = (1...100).map { index in
            "    let cachedHeight_\(index) = layoutCache.value(for: message.id, width: width)"
        }.joined(separator: "\n")

        return [
            ToolCallItem(
                toolName: "fs/read_text_file",
                path: "Sources/AnyDiffUI/Agent/AgentChatScrollView.swift",
                descriptionText: "Read the native chat scroll view and locate streaming layout work.",
                startLine: 411,
                endLine: 680,
                summary: "Read 270 lines successfully",
                status: .completed
            ),
            ToolCallItem(
                toolName: "search_files",
                path: "Sources/AnyDiffUI/Agent",
                descriptionText: "Search for full message rebuilds, resize callbacks, and markdown parsing hotspots.",
                summary: "Found 14 matching call sites across 6 files",
                status: .completed
            ),
            ToolCallItem(
                toolName: "run_command",
                descriptionText: "Run focused agent model tests before exercising the heavy UI fixture.",
                command: "swift test --filter AgentSessionManagerTests",
                output: commandOutput,
                status: .completed
            ),
            ToolCallItem(
                toolName: "replace_file_content",
                path: "Sources/AnyDiffUI/Agent/AgentChatScrollView.swift",
                descriptionText: "Cache message measurements, debounce resize layout, and keep streaming updates cheap.",
                startLine: 480,
                endLine: 650,
                oldContent: oldLines,
                newContent: newLines,
                status: .completed
            ),
            ToolCallItem(
                toolName: "fs/write_text_file",
                path: "Tests/AnyDiffCoreTests/AgentSessionManagerTests.swift",
                descriptionText: "Add regression coverage for large mock messages and mixed tool timelines.",
                newContent: (1...34).map { "    XCTAssertGreaterThan(mockManager.messages[11].content.count, \($0 * 20))" }.joined(separator: "\n"),
                status: .completed
            ),
            ToolCallItem(
                toolName: "run_command",
                descriptionText: "Run the complete core test suite after the UI stress scenario is loaded.",
                command: "swift test -c debug",
                output: "Test Suite 'AnyDiffCoreTests' passed (94 tests in 0.91s)\nNo failures.\nHeavy mock fixture: 6 tool calls, 10,000-line edit, 180 output lines.",
                status: .completed
            )
        ]
    }

    public override func cancel() {
        mockTask?.cancel()
        mockTask = nil
        status = .idle
        statusMessage = "Stopped"
        if let last = messages.last, last.isStreaming {
            if let idx = messages.firstIndex(where: { $0.id == last.id }) {
                messages[idx].isStreaming = false
            }
        }
    }

    public override func clearSession() {
        mockTask?.cancel()
        mockTask = nil
        loadSampleConversation()
    }
}
