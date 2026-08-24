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
        self.contextUsagePercentage = 68
        self.status = .idle
        self.initializationState = .ready
        if loadFixtures {
            self.loadSampleConversation()
        }
    }

    public func loadSampleConversation() {
        let msg1 = AgentMessage(
            role: .user,
            content: "Привет! Что умеет AnyDiff и в чем его главная фишка?"
        )

        let msg2 = AgentMessage(
            role: .assistant,
            content: """
            Привет, бро! 🚀 **AnyDiff** — это нативный и ультрабыстрый macOS Git/Diff клиент на Swift без внешних зависимостей.

            ### ✨ Ключевые возможности:
            - **Двухсторонний и unified дифф** с пословной подсветкой изменений (Intra-line word diff).
            - **Виртуализированный редактор MultiBuffer**: плавный скролл на миллионах строк с нулевой задержкой.
            - **Прямое редактирование рабочих деревьев**: возможность вносить правки прямо в окне сравнения с мгновенным пересчетом Myers diff.
            - **Встроенный агентный режим (ACP)**: контекстный ИИ-ассистент с поддержкой инструментов файловой системы и терминала.
            """,
            thought: "Формирую обзорную сводку возможностей AnyDiff для пользователя.",
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
            content: "как устроена виртуализация MultiBuffer?"
        )

        let msg4 = AgentMessage(
            role: .assistant,
            content: """
            В AnyDiff виртуализация построена на трехуровневой модели:

            1. **Координатная сетка**: непрерывный массив строк с ленивым развертыванием контекста вокруг измененных ханков.
            2. **Viewport Culling**: отрисовываются только строки, попадающие в видимую область экрана `[firstVisibleLine, lastVisibleLine]` + 10 строк буфера.
            3. **Zero-Copy Hunks**: неизмененные срезы файла читаются без аллокации строк в heap.

            ```swift
            // Пример расчета видимого диапазона строк
            let startLine = max(0, Int(scrollOffset / lineHeight) - overscan)
            let endLine = min(totalLines, startLine + visibleLineCount + overscan * 2)
            ```
            """,
            thought: "Вспоминаю архитектуру AnyDiffCore/MultiBuffer и виртуализированный EditorHostView.",
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
            content: "запусти тесты и проверь стабильность"
        )

        let msg6 = AgentMessage(
            role: .assistant,
            content: """
            Все тесты и бенчмарки пройдены успешно! ⚡️

            - **Unit Tests**: 79 passed (0 failures) in `0.68s`
            - **Myers Diff Throughput**: `~1.2ms` на 10 000 строк с обрезкой общих префиксов и суффиксов.
            - **Memory Packing**: 0 утечек памяти.

            ```
            ✔ Test Suite 'Selected tests' passed (79 tests in 0.685s)
            ✔ Benchmark 'MyersDiffPruning' took 0.0012s (10k lines)
            ```

            > 💡 Алгоритм Myers оптимизирован за счет $O(ND)$ сложности с быстрым отсечением идентичных строк на концах.
            """,
            thought: "Запускаю тестовый раннер через ACP terminal/create и анализирую вывод XCTest.",
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
            content: "покажи дифф добавления горячей клавиши Cmd+Opt+A"
        )

        let msg8 = AgentMessage(
            role: .assistant,
            content: """
            Вот дифф добавления пункта меню в `AppDelegate+Menu.swift`:

            ```diff
            + let agentItem = NSMenuItem(
            +     title: "Toggle Agent Panel",
            +     action: #selector(toggleAgentPanel),
            +     keyEquivalent: "a"
            + )
            + agentItem.keyEquivalentModifierMask = [.command, .option]
            + viewMenu.addItem(agentItem)
            ```

            Файл обновлен и проверен компилятором.
            """,
            thought: "Формирую пример изменения меню в AppDelegate+Menu.swift.",
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
            content: "как парсятся заголовки ханков git diff?"
        )

        let msg10 = AgentMessage(
            role: .assistant,
            content: """
            Заголовок ханка имеет формат: `@@ -старт,длина +старт,длина @@ [контекст]`.

            Парсер `DiffParser.swift` разбирает его за один проход без регулярных выражений:
            - `-l,s` — диапазон строк в старом файле (left side).
            - `+l,s` — диапазон строк в новом файле (right side).
            - Если длина `s` опущена, она считается равной `1`.
            """,
            thought: "Анализирую парсер диффов DiffParser.swift.",
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
            content: "напиши стишок про AnyDiff!"
        )

        let msg12 = AgentMessage(
            role: .assistant,
            content: makeStressResponse(prompt: "Демонстрация тяжёлого mock-сценария"),
            thought: "Собираю большой ответ из нескольких markdown-блоков и сверяю результаты инструментов.",
            toolCalls: makeStressToolCalls(),
            isStreaming: false
        )

        self.messages = [msg1, msg2, msg3, msg4, msg5, msg6, msg7, msg8, msg9, msg10, msg11, msg12]
        self.contextUsagePercentage = 68
        self.status = .idle
        self.statusMessage = nil
    }

    public override func sendPrompt(_ text: String, workingDirectory: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = AgentMessage(role: .user, content: trimmed)
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

            let isEditRequest = trimmed.lowercased().contains("edit") || trimmed.lowercased().contains("правк") || trimmed.lowercased().contains("измен")

            if isEditRequest {
                self.messages[idx].thought = "Анализирую файл AppDelegate+Menu.swift и формирую правку для добавления пункта меню агента."

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
                    self.makeStressResponse(prompt: "Правка по запросу «\(trimmed)»"),
                    messageId: assistantMsgId
                ) else { return }
            } else {
                self.messages[idx].thought = "Анализирую запрос «\(trimmed)»...\nПроверяю контекст изменений и структуру файлов."

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

                // 3. Stream in medium-sized chunks. This is much closer to
                // ACP token delivery while avoiding an artificial SwiftUI
                // publish for every single word.
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

    private func makeStressResponse(prompt: String) -> String {
        let diagnostics = (1...42).map { index in
            "- `event_\(String(format: "%03d", index))`: layout pass \((index % 7) + 1), measured \(118 + index) nodes, cache hit \(index % 4 != 0 ? "yes" : "no")"
        }.joined(separator: "\n")

        let code = (1...72).map { index in
            "    let result_\(index) = await pipeline.stage(\(index), width: viewportWidth, cache: layoutCache)"
        }.joined(separator: "\n")

        return """
        # Разбор запроса

        Запрос: `\(prompt)`

        Готово, бро. Я прогнал сценарий через несколько инструментов и собрал большой ответ, чтобы панель можно было честно проверить под нагрузкой. Ниже есть длинный текст, списки, цитата, shell-вывод и большой Swift-блок. В реальном ACP такие куски приходят постепенно, поэтому во время стрима интерфейс должен оставаться отзывчивым.

        ## Что проверено

        - Стабильность layout при изменении ширины панели.
        - Сохранение scroll anchor, когда пользователь находится не внизу.
        - Несколько tool calls с разными статусами и раскрываемыми деталями.
        - Большие ответы без пересоздания уже отрисованных карточек.
        - Переключение между plain text и syntax-highlighted кодом после завершения стрима.

        ### Диагностика layout

        \(diagnostics)

        > Важно: tool output намеренно большой. Карточка строит его детали лениво — тяжёлый текст появляется только после клика по конкретному инструменту.

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

        ## Итог

        Для стрима оптимальный путь — публиковать небольшие пачки текста, обновлять только изменившуюся последнюю ячейку, кэшировать высоты неизменившихся сообщений и не запускать implicit animations на каждый chunk. При ресайзе layout нужно немного дебаунсить, а финальную ширину применять сразу после окончания жеста.
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
