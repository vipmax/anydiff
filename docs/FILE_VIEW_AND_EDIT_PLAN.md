# In-Editor File Navigation, MultiBuffer Integration & Editing Plan

## 1. Objective

Enable seamless, in-editor viewing and editing of files referenced in the Agent Chat (and elsewhere) within AnyDiff's primary `MultiBuffer`, rather than delegating directly to external system applications.

Files opened from chat links will:
1. Open directly in the active MultiBuffer editor at the target line/range.
2. Be inserted in **lexicographical (alphabetical) order**—the exact position they would occupy in Git status/diff—to guarantee zero viewport jumps when the user edits and saves, and Git refreshes the diff.
3. Support full in-place editing, undo/redo (`⌘Z`/`⇧⌘Z`), and disk saving (`⌘S` / debounced autosave).
4. Provide an intuitive **`✕` close button** in the file header (both static and sticky) as well as a keyboard shortcut (`⌘W`) to close the file.
5. Offer an explicit **"Open in External IDE"** action (Cursor / VS Code / Xcode) via a header action or `⌥ Option + Click` for heavy development workflows.

---

## 2. Architecture & Data Flow

### 2.1 Lexicographical Insertion into `MultiBuffer` and `fileDiffs`

Git outputs diffs and file statuses in alphabetical order (`displayPath < other.displayPath`).
When a file link is clicked:
1. If the file is **already present** in `activeDisplayMap`:
   - Use `CustomMultiBufferEditorView.navigateTo(filePath:lineNumber:endLineNumber:)` to center and focus.
2. If the file is **not in the diff**:
   - Read the file content from disk (`String(contentsOfFile:encoding:)`).
   - Create a full-file `Buffer`:
     ```swift
     let buffer = Buffer(
         filePath: relativeOrDisplayPath,
         lines: lines,
         language: Buffer.detectLanguage(for: relativeOrDisplayPath),
         baselineLines: lines,
         totalAdditions: 0,
         totalDeletions: 0,
         startLineNumber: 1,
         fullDiskPath: absoluteDiskPath,
         diskFileLineCount: lines.count
     )
     buffer.isFullFile = true
     ```
   - Create a corresponding `Excerpt`:
     ```swift
     let excerpt = Excerpt(
         bufferId: buffer.id,
         filePath: relativeOrDisplayPath,
         fileStatus: .unmodified, // clean inspected file
         bufferRange: 0..<buffer.lineCount,
         hunk: nil,
         isCollapsed: false,
         isFileStart: true
     )
     ```
   - Determine the correct alphabetical index:
     ```swift
     let insertIndex = fileDiffs.firstIndex(where: {
         $0.displayPath.localizedStandardCompare(relativeOrDisplayPath) == .orderedDescending
     }) ?? fileDiffs.count
     ```
   - Insert into `fileDiffs` and `multiBuffer` at `insertIndex`.
   - Register the file in `manuallyOpenedFilePaths: Set<String>` to prevent automatic background Git refreshes from discarding it while clean.
   - Rebuild `displayMap` and navigate to the target line.

---

### 2.2 File Header Close Button (`✕`) & Hit-Testing

In `CustomMultiBufferEditorView.swift`:
1. **Layout & Drawing (`drawExcerptHeader`):**
   - In both static excerpt headers and the sticky header, render a circular `✕` icon button on the right side:
     - Normal state: subtle gutter foreground (`theme.gutterForeground.withAlphaComponent(0.6)`).
     - Hovered state: highlighted pill/circle with higher contrast.
   - Geometry: ~20×20 pt hit area, vertically centered in the 32 pt header.
2. **Hit-Testing & Interaction (`mouseDown` & `mouseMoved`):**
   - Check if click hits the close button:
     - If yes: invoke `closeFile(filePath:)`. Do **not** trigger excerpt collapse/expand.
   - Update cursor to `pointingHand` when hovering over the close button.
3. **Keyboard Shortcut (`⌘W`):**
   - In `performKeyEquivalent`, intercept `⌘W` when focused in the editor:
     - Resolve the currently focused file from the cursor position.
     - Call `closeFile(filePath:)`.

---

### 2.3 Editing & Git Reconciliation

1. **In-place Editing:**
   - Because `Buffer.isFullFile = true` and `Buffer.fullDiskPath = absoluteDiskPath`, typing and edits immediately mutate the buffer and trigger `scheduleDebouncedSave()`.
   - Pressing `⌘S` writes immediately to disk via `flushImmediateSave()`.
2. **Git Watcher Reconciliation:**
   - Once edited and saved to disk, Git watcher fires.
   - Git diff now includes this file!
   - Because the file was already placed at its exact alphabetical position, replacing it with the Git diff hunk (or full file context) causes **zero vertical shifts or jumping**.
   - If user reverts all changes and clicks `✕`, the file cleanly leaves the editor.

---

### 2.4 External IDE Handoff (`⌥ Option + Click` & Header Button)

For cases where the user wants full LSP / compiler diagnostics:
1. **Shortcut in Chat:**
   - Holding `⌥ Option` while clicking a file link opens the file in the external editor (Cursor / VS Code / Xcode) positioned at the line anchor:
     ```bash
     cursor -g path/to/file:line
     # or code -g path/to/file:line
     # or fallback to NSWorkspace.shared.open
     ```
2. **Header Action:**
   - Add a small arrow/external icon `↗` next to the close button in the header.

---

## 3. Implementation Steps

1. **`AnyDiffCore` / `DiffHunk.swift`:**
   - Add `.unmodified` case to `FileDiffStatus` if not already present, representing an inspected clean file.

2. **`MainWindowView.swift`:**
   - Add `manuallyOpenedFilePaths: Set<String>`.
   - Implement `openFileInEditor(path: String, line: Int?, endLine: Int?)`:
     - Resolves relative and absolute disk paths.
     - Inserts sorted into `fileDiffs` and `multiBuffer`.
     - Rebuilds `displayMap` and posts `.focusFileInEditor`.
   - Implement `closeFileFromEditor(filePath: String)`:
     - Removes from `fileDiffs`, `multiBuffer`, and `manuallyOpenedFilePaths`.
     - Rebuilds `displayMap`.
   - Update `handleOpenURL` to call `openFileInEditor` instead of `NSWorkspace.shared.open`.
   - Integrate `manuallyOpenedFilePaths` preservation inside `loadCurrentDirectoryDiff()`.

3. **`CustomMultiBufferEditorView.swift`:**
   - Add `closeButtonRect(forHeaderRect:)` helper.
   - Render `✕` in `drawExcerptHeader`.
   - Add hover tracking and click interception in `mouseDown`.
   - Add delegate callback `editorDidRequestCloseFile(filePath: String)`.
   - Bind `⌘W` in `performKeyEquivalent`.

4. **Testing:**
   - Unit tests for alphabetical insertion and removal in `MultiBuffer`.
   - Unit tests verifying `FileLinkParser` integration and file opening.
   - Manual verification of chat link clicks, line targeting, editing, saving, and closing.

---

# Описание плана на русском языке

## 1. Цель
Сделать так, чтобы при клике на файл или ссылку со строкой (`#L42`) в чате агента (или в любом другом месте) файл открывался **прямо внутри AnyDiff** в основном редакторе `MultiBuffer`, а не выбрасывал пользователя в дефолтное системное приложение (Xcode/TextEdit).

Файл должен:
1. Открываться в активном редакторе AnyDiff сразу на нужной строке или диапазоне строк.
2. Вставляться **строго по алфавиту** — ровно на то место, где он находился бы в Git-диффе. Благодаря этому, когда пользователь начинает редактировать файл и сохраняет его (`⌘S`), Git подхватывает изменения без каких-либо визуальных скачков или смещения экрана.
3. Поддерживать полноценное редактирование на месте, отмену/повтор (`⌘Z` / `⇧⌘Z`) и сохранение на диск (`⌘S` или debounced autosave).
4. Иметь интуитивную **кнопку закрытия `✕`** в шапке файла (как в обычной, так и в прилипающей sticky-шапке при скролле), а также закрываться горячей клавишей `⌘W`.
5. Предоставлять возможность открыть файл в сторонней IDE (Cursor / VS Code / Xcode) через кнопку в шапке `↗` или по клику с зажатым `⌥ Option` сразу на целевой строке.

---

## 2. Архитектура и поток данных

### 2.1 Алфавитная вставка в `MultiBuffer` и `fileDiffs`
Git всегда упорядочивает измененные файлы по алфавиту (`displayPath < other.displayPath`).
При клике на ссылку:
1. Если файл **уже присутствует** в `activeDisplayMap`:
   - Вызываем `navigateTo(filePath:lineNumber:endLineNumber:)` для центрирования экрана и подсветки строки.
2. Если файла **нет в текущем диффе**:
   - Читаем файл с диска (`String(contentsOfFile:encoding:)`).
   - Создаем полный буфер `Buffer` (`isFullFile = true`, `fullDiskPath = absoluteDiskPath`, `startLineNumber = 1`).
   - Создаем `Excerpt` со статусом `.unmodified` (чистый просматриваемый файл).
   - Находим правильный индекс по алфавиту среди `fileDiffs` (`localizedStandardCompare`).
   - Вставляем файл в `fileDiffs` и `multiBuffer` на эту позицию.
   - Запоминаем файл в `manuallyOpenedFilePaths: Set<String>`, чтобы фоновые обновления Git не закрывали открытый пользователем чистый файл.
   - Перестраиваем `displayMap` и переходим к нужной строке.

### 2.2 Кнопка закрытия `✕` в шапке файла
В `CustomMultiBufferEditorView.swift`:
1. **Отрисовка:**
   - В правой части шапки файла (и обычной, и плавающей sticky) рисуем круглую кнопку `✕`.
   - В обычном состоянии — приглушенный цвет `gutterForeground`, при наведении мыши — подсветка и курсор `pointingHand`.
2. **Обработка кликов (`mouseDown`):**
   - Если клик пришелся в зону кнопки `✕` — вызывается закрытие файла `closeFile(filePath:)` без сворачивания/разворачивания секции (collapse/expand).
3. **Шорткат `⌘W`:**
   - При нажатии `⌘W` в редакторе закрывается файл, в котором находится текстовый курсор.

### 2.3 Редактирование и интеграция с Git
1. **Редактирование на месте:**
   - Поскольку у буфера задан `fullDiskPath`, любое редактирование сразу меняет буфер и ставит в очередь автосохранение.
   - Нажатие `⌘S` мгновенно записывает файл на диск через `flushImmediateSave()`.
2. **Бесшовный переход в Git diff:**
   - Как только файл сохранен, файловый вотчер AnyDiff видит изменения от Git.
   - Поскольку файл уже стоит на своем законном алфавитном месте, он плавно обновляется без скачков скролла и прыжков контента.
   - Если пользователь закрывает файл по `✕` (и изменений нет), он просто удаляется из буфера.

### 2.4 Открытие во внешней IDE (`⌥ Option + клик` и кнопка `↗`)
- Если пользователю нужен тяжелый рефакторинг или запуск тестов в основной IDE:
  - Клик по ссылке в чате с зажатым `⌥ Option` или кнопка `↗` в шапке вызывает `cursor -g file:line` / `code -g file:line`, открывая IDE ровно на нужной строке.

---

## 3. Шаги реализации

1. **`AnyDiffCore` / `DiffHunk.swift`:**
   - Добавить статус `.unmodified` для файлов, открытых для чтения/редактирования без изменений в Git.
2. **`MainWindowView.swift`:**
   - Добавить хранилище `manuallyOpenedFilePaths: Set<String>`.
   - Реализовать `openFileInEditor(path:line:endLine:)` с алфавитной вставкой.
   - Реализовать `closeFileFromEditor(filePath:)` с удалением из буфера и боковой панели.
   - Обновить `handleOpenURL` для использования `openFileInEditor`.
   - Сохранять открытые файлы при перезагрузке диффа вотчером.
3. **`CustomMultiBufferEditorView.swift`:**
   - Отрисовать `✕` в `drawExcerptHeader`.
   - Обработать наведение и клик по `✕`.
   - Добавить шорткат `⌘W`.
4. **Тесты:**
   - Unit-тесты на вставку по алфавиту, удаление и навигацию по строкам.
