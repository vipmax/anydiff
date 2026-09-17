# Parallel Agent Session Isolation via Git Worktrees (Plan)

## 1. Executive Summary & Objective

When multiple AI agents operate concurrently in AnyDiff on the same project repository, executing file edits and terminal commands in a single shared working directory leads to severe concurrency issues:
1. **Dirty Diff Bleed**: An agent inspecting `git diff` against its turn snapshot captures file modifications made by other agents (or external editors), displaying incorrect files in the live banner (`AgentLiveChangesBannerView`, e.g. *«4 files changed +223 -9»*).
2. **File System Race Conditions**: If Agent 1 edits `A.swift` and runs tests (`swift test`), while Agent 2 simultaneously introduces a syntax error in `B.swift`, Agent 1's compilation fails. Agent 1 enters an erroneous self-correction loop attempting to fix unrelated code.
3. **Dirty Rollbacks / Destructive Reverts**: Reverting or reviewing a turn for Agent 1 inadvertently rolls back or presents changes authored by Agent 2.

**Goal**: Isolate each agent session into an ephemeral, zero-copy **Git Worktree** (`.git/anydiff-worktrees/<session-id>`). Each agent operates in its own isolated filesystem sandbox, preserving the user's primary working directory untouched until changes are reviewed and applied.

---

## 2. Architectural Overview

```
Main Project Repo: /Users/max/dev/my-project/
│
├── .git/
│   ├── config, objects/, refs/               <-- Shared Git database (zero duplicate storage)
│   └── anydiff-worktrees/                    <-- Ephemeral sandboxes (ignored by Git)
│       ├── session-a1b2c3d4/                 <-- Isolated working copy for Agent 1
│       │   ├── Sources/
│       │   └── Package.swift
│       └── session-e5f6g7h8/                 <-- Isolated working copy for Agent 2
│           ├── Sources/
│           └── Package.swift
│
└── (Working Tree)                            <-- User's active code in Xcode / VS Code
```

### Key Properties
- **Zero Storage Bloat**: `git worktree` reuses the existing `.git/objects` and packs. No repository cloning is needed. Creation takes ~100–300 ms.
- **Physical OS Isolation**: File writes, terminal builds, and test runs are completely segregated per agent.
- **Pure Diffs**: `git diff` in Agent 1's worktree reflects strictly Agent 1's mutations.
- **Non-Destructive User Experience**: The user's main workspace remains unmodified while background agents experiment, test, and polish code.

---

## 3. Core Components & Responsibilities

### 3.1 `AgentWorktreeManager` (`Sources/AnyDiffCore/Agent/AgentWorktreeManager.swift`)

A dedicated actor/service managing the lifecycle of ephemeral worktrees:

```swift
public final class AgentWorktreeManager: Sendable {
    public static let shared = AgentWorktreeManager()

    /// Creates an isolated worktree for a session inside `<repoRoot>/.git/anydiff-worktrees/<sessionId>`
    /// - Parameters:
    ///   - sessionId: Unique agent session UUID.
    ///   - repositoryPath: Path to the main Git repository.
    /// - Returns: Absolute path to the isolated worktree directory.
    public func createWorktree(for sessionId: UUID, in repositoryPath: String) async throws -> String

    /// Prepares base commit or uncommitted snapshot:
    /// If user has dirty changes in the main working tree, creates a temporary stash/commit
    /// to branch from, ensuring the agent sees the user's latest code.
    public func captureBaseSnapshot(repositoryPath: String) throws -> String

    /// Generates unified diff between worktree and main repository.
    public func computeWorktreeDiff(worktreePath: String, baseRef: String) async throws -> (Data?, AgentEditedFilesSummary?)

    /// Applies approved agent changes into the main working tree (via `git apply` or cherry-pick).
    public func applyToMainRepository(from worktreePath: String, into mainRepoPath: String) async throws -> ApplyResult

    /// Deletes the worktree and cleans up Git metadata (`git worktree remove --force`).
    public func removeWorktree(for sessionId: UUID, in repositoryPath: String) async throws

    /// Garbage-collects orphaned worktrees on app launch/quit.
    public func pruneOrphanedWorktrees(in repositoryPath: String) async
}
```

### 3.2 Integration with `ACPAgentSessionManager`

1. **Initialization / Session Start**:
   - Instead of passing `currentWorkingDirectory = mainRepoPath`, check if `isGitRepository(at: mainRepoPath)`.
   - Call `AgentWorktreeManager.shared.createWorktree(for: sessionId, in: mainRepoPath)`.
   - Start the ACP client (`codex`, `claude`, etc.) with `workingDirectory = worktreePath`.
2. **Turn Diffs**:
   - `updateLiveGitDiffState()` runs against `worktreePath`.
   - The live banner (`AgentLiveChangesBannerView`) only displays files changed within this agent's sandbox.
3. **Session Teardown**:
   - On session deletion, window close, or explicit discard: `AgentWorktreeManager.shared.removeWorktree(for: sessionId, in: mainRepoPath)`.

### 3.3 Integration with `AgentSessionCoordinator`

- Track worktree status in `AgentSessionItem`:
  ```swift
  public var worktreePath: String?
  public var isWorktreeIsolated: Bool { worktreePath != nil }
  ```
- Startup / Shutdown lifecycle hooks ensuring worktrees are pruned when tabs are closed.

---

## 4. Worktree Lifecycle & User Flow

### Step 1: Session Creation (Zero-friction Setup)
1. User clicks `+` or opens a secondary agent tab in AnyDiff.
2. AnyDiff identifies the main repository root.
3. If main repo has uncommitted changes:
   - Create a lightweight shadow commit: `git stash create`.
   - Base the worktree on this commit (so the agent has the user's latest edits without requiring a manual commit).
4. Run:
   ```bash
   git worktree add --detach .git/anydiff-worktrees/<session-id> <baseCommitHash>
   ```
5. Agent process starts with cwd `.git/anydiff-worktrees/<session-id>`.

### Step 2: Parallel Execution
- Agent 1 works in `.git/anydiff-worktrees/session-1`.
- Agent 2 works in `.git/anydiff-worktrees/session-2`.
- Both can run `swift test`, `cargo build`, or file edits simultaneously without collisions.
- The live banner in AnyDiff reflects **only** the active agent's mutations.

### Step 3: Review & Apply Flow
1. **Review**: Clicking **Review ↗** in the chat loads the diff between the agent's worktree and the main repo into AnyDiff's unified/split viewer.
2. **Apply Changes**:
   - User clicks **Apply / Accept All** (or selectively stages hunks).
   - AnyDiff extracts the patch:
     ```bash
     git diff <baseCommit> HEAD
     ```
   - Applies the patch cleanly to the main repository:
     ```bash
     git -C <mainRepoPath> apply --3way <patchFile>
     ```
   - If conflicts arise, AnyDiff's MultiBuffer surfaces the 3-way conflict markers for resolution.
3. **Discard / Revert**:
   - Simply deletes or resets the worktree. Main repository remains completely untouched.

---

## 5. Handling Edge Cases & Fallbacks

| Edge Case | Solution |
| :--- | :--- |
| **Non-Git Workspace** | If the folder is not a Git repo, gracefully fall back to direct file edits (with path-level session tracking so the banner only tracks files written by this session). |
| **Crash / Unexpected Quit** | On app launch, `AgentWorktreeManager.pruneOrphanedWorktrees` inspects `.git/anydiff-worktrees/` and removes any dangling directories older than the active app instance. |
| **Dependencies / Build Artifacts** | Most build tools (`swift build`, `node_modules`, `target`) build inside the worktree. For large `node_modules`, symlink to main repo or allow configurable worktree caching. |
| **User Edits Main Repo During Agent Turn** | 3-way merge (`git apply --3way`) during Apply ensures changes in main are preserved without being blindly overwritten. |

---

## 6. Implementation Milestones

### Phase 1: `AgentWorktreeManager` Core Service
- [ ] Implement `AgentWorktreeManager` actor with `createWorktree`, `removeWorktree`, and `pruneOrphanedWorktrees`.
- [ ] Add unit tests verifying creation, isolation, git command execution, and cleanup.

### Phase 2: Session Manager Wiring
- [ ] Wire `ACPAgentSessionManager` to request a worktree on startup when in a Git repository.
- [ ] Pass worktree path as the ACP client's `cwd`.
- [ ] Direct `AgentGitChangesDetector` to operate in the worktree path.

### Phase 3: Review & Apply UI
- [ ] Update `MainWindowView` Review flow to support applying worktree patches back to the main repository.
- [ ] Add «Apply to Main Workspace» / «Discard» controls to the Review header and completed message cards.
- [ ] Automatic cleanup of worktree on session closure.

### Phase 4: Verification & Stress Testing
- [ ] Launch 2 live agent sessions in parallel.
- [ ] Verify Agent 1 edits `FileA` while Agent 2 edits `FileB`.
- [ ] Confirm banners, tool call diffs, and review cards are 100% isolated with zero bleed.

---

## 7. Performance Targets & Resource Allocation

| Metric | Target | Verification Method |
| :--- | :--- | :--- |
| **Worktree Creation Latency** | `< 250 ms` | Benchmark `AgentWorktreeManager.createWorktree` against 10k-file repositories. |
| **Storage Overhead** | `0 bytes` (excluding modified files) | Verifying `.git/objects` and packs are shared, no duplicate blobs cloned. |
| **Worktree Teardown Latency** | `< 100 ms` | Asynchronous `git worktree remove --force` on session termination. |
| **Orphaned Worktree Sweep** | `< 50 ms` at launch | Background scanning of `.git/anydiff-worktrees/` on application boot. |

---

## 8. Sandboxing & Path Boundary Invariants

1. **Symlink Containment**: Prevent rogue agent commands or file edits from traversing symlinks outside the worktree sandbox.
2. **Path Normalization**: Validate that all ACP file tool requests (`fs/read_text_file`, `fs/write_text_file`) resolve strictly within `worktreePath`.
3. **Subprocess Environment Isolation**: Pass explicit `GIT_WORK_TREE` and `GIT_DIR` environment variables to terminal execution tools (`execute_command`) so child git commands never accidentally mutate the parent repository.

---

# Изоляция параллельных сессий агентов через Git Worktrees (План)

## 1. Краткое резюме и цель

Когда несколько ИИ-агентов работают параллельно в AnyDiff над одним и тем же репозиторием проекта, выполнение правок файлов и команд в терминале в единой общей рабочей директории приводит к критическим проблемам параллелизма:
1. **Утечка «грязного» диффа (Dirty Diff Bleed)**: Агент, анализирующий `git diff` относительно снимка своего шага (turn snapshot), перехватывает изменения файлов, сделанные другими агентами (или внешними редакторами), из-за чего в живом баннере (`AgentLiveChangesBannerView`, например, *«изменено 4 файла +223 -9»*) отображаются чужие файлы.
2. **Состояние гонки в файловой системе (Race Conditions)**: Если Агент 1 редактирует `A.swift` и запускает тесты (`swift test`), в то время как Агент 2 одновременно допускает синтаксическую ошибку в `B.swift`, компиляция у Агента 1 ломается. Агент 1 входит в ошибочный цикл автоисправления, пытаясь починить чужой код.
3. **Некорректные откаты / Деструктивные реверты (Dirty Rollbacks)**: Откат или просмотр шага Агента 1 непреднамеренно откатывает или выводит изменения, сделанные Агентом 2.

**Цель**: Изолировать каждую сессию агента в эфемерный, не требующий дублирования дискового пространства **Git Worktree** (`.git/anydiff-worktrees/<session-id>`). Каждый агент работает в собственной изолированной песочнице на уровне файловой системы, сохраняя основную рабочую директорию пользователя нетронутой до тех пор, пока изменения не будут проверены и применены.

---

## 2. Архитектурный обзор

```
Основной репозиторий проекта: /Users/max/dev/my-project/
│
├── .git/
│   ├── config, objects/, refs/               <-- Общая база данных Git (ноль дублирования места)
│   └── anydiff-worktrees/                    <-- Эфемерные песочницы (игнорируются Git)
│       ├── session-a1b2c3d4/                 <-- Изолированная рабочая копия для Агента 1
│       │   ├── Sources/
│       │   └── Package.swift
│       └── session-e5f6g7h8/                 <-- Изолированная рабочая копия для Агента 2
│           ├── Sources/
│           └── Package.swift
│
└── (Рабочее дерево)                          <-- Активный код пользователя в Xcode / VS Code
```

### Ключевые свойства
- **Ноль избыточного дискового пространства**: `git worktree` повторно использует существующие `.git/objects` и паки. Клонирование репозитория не требуется. Создание занимает ~100–300 мс.
- **Физическая изоляция на уровне ОС**: Запись файлов, сборка в терминале и запуск тестов полностью изолированы для каждого агента.
- **Чистые диффы**: `git diff` в worktree Агента 1 отражает исключительно изменения Агента 1.
- **Безопасный пользовательский опыт**: Основное рабочее пространство пользователя остается неизменным, пока фоновые агенты экспериментируют, тестируют и дорабатывают код.

---

## 3. Основные компоненты и зоны ответственности

### 3.1 `AgentWorktreeManager` (`Sources/AnyDiffCore/Agent/AgentWorktreeManager.swift`)

Выделенный актор/сервис, управляющий жизненным циклом эфемерных worktree:

```swift
public final class AgentWorktreeManager: Sendable {
    public static let shared = AgentWorktreeManager()

    /// Создает изолированный worktree для сессии внутри `<repoRoot>/.git/anydiff-worktrees/<sessionId>`
    /// - Parameters:
    ///   - sessionId: Уникальный UUID сессии агента.
    ///   - repositoryPath: Путь к основному Git-репозиторию.
    /// - Returns: Абсолютный путь к директории изолированного worktree.
    public func createWorktree(for sessionId: UUID, in repositoryPath: String) async throws -> String

    /// Подготавливает базовый коммит или снимок незакоммиченных изменений:
    /// Если у пользователя есть незакоммиченные изменения в основном дереве, создается временный stash/коммит
    /// для ветвления, гарантируя, что агент увидит актуальный код пользователя.
    public func captureBaseSnapshot(repositoryPath: String) throws -> String

    /// Генерирует unified diff между worktree и основным репозиторием.
    public func computeWorktreeDiff(worktreePath: String, baseRef: String) async throws -> (Data?, AgentEditedFilesSummary?)

    /// Применяет одобренные изменения агента в основное рабочее дерево (через `git apply` или cherry-pick).
    public func applyToMainRepository(from worktreePath: String, into mainRepoPath: String) async throws -> ApplyResult

    /// Удаляет worktree и очищает метаданные Git (`git worktree remove --force`).
    public func removeWorktree(for sessionId: UUID, in repositoryPath: String) async throws

    /// Сборка мусора для забытых/осиротевших worktree при запуске/завершении приложения.
    public func pruneOrphanedWorktrees(in repositoryPath: String) async
}
```

### 3.2 Интеграция с `ACPAgentSessionManager`

1. **Инициализация / Старт сессии**:
   - Вместо передачи `currentWorkingDirectory = mainRepoPath`, проверяется `isGitRepository(at: mainRepoPath)`.
   - Вызывается `AgentWorktreeManager.shared.createWorktree(for: sessionId, in: mainRepoPath)`.
   - ACP-клиент (`codex`, `claude` и т. д.) запускается с `workingDirectory = worktreePath`.
2. **Диффы шага (Turn Diffs)**:
   - `updateLiveGitDiffState()` выполняется относительно `worktreePath`.
   - Живой баннер (`AgentLiveChangesBannerView`) отображает файлы, измененные только внутри песочницы данного агента.
3. **Завершение сессии**:
   - При удалении сессии, закрытии окна или явном сбросе: `AgentWorktreeManager.shared.removeWorktree(for: sessionId, in: mainRepoPath)`.

### 3.3 Интеграция с `AgentSessionCoordinator`

- Отслеживание статуса worktree в `AgentSessionItem`:
  ```swift
  public var worktreePath: String?
  public var isWorktreeIsolated: Bool { worktreePath != nil }
  ```
- Хуки жизненного цикла запуска / завершения, гарантирующие удаление worktree при закрытии вкладок.

---

## 4. Жизненный цикл Worktree и пользовательский сценарий

### Шаг 1: Создание сессии (Бесшовный запуск)
1. Пользователь нажимает `+` или открывает вторую вкладку агента в AnyDiff.
2. AnyDiff определяет корень основного репозитория.
3. Если в основном репозитории есть незакоммиченные изменения:
   - Создается легковесный теневой коммит: `git stash create`.
   - Worktree базируется на этом коммите (чтобы у агента были свежие правки пользователя без необходимости ручного коммита).
4. Выполняется:
   ```bash
   git worktree add --detach .git/anydiff-worktrees/<session-id> <baseCommitHash>
   ```
5. Процесс агента стартует с cwd `.git/anydiff-worktrees/<session-id>`.

### Шаг 2: Параллельное выполнение
- Агент 1 работает в `.git/anydiff-worktrees/session-1`.
- Агент 2 работает в `.git/anydiff-worktrees/session-2`.
- Оба могут одновременно выполнять `swift test`, `cargo build` или редактировать файлы без коллизий.
- Живой баннер в AnyDiff отражает **только** изменения активного агента.

### Шаг 3: Просмотр и применение изменений
1. **Просмотр (Review)**: Клик на **Review ↗** в чате загружает diff между worktree агента и основным репозиторием в unified/split просмотрщик AnyDiff.
2. **Применение изменений**:
   - Пользователь нажимает **Apply / Accept All** (или выборочно применяет ханковые правки).
   - AnyDiff формирует патч:
     ```bash
     git diff <baseCommit> HEAD
     ```
   - Аккуратно накладывает патч на основной репозиторий:
     ```bash
     git -C <mainRepoPath> apply --3way <patchFile>
     ```
   - При возникновении конфликтов MultiBuffer в AnyDiff отображает 3-way маркеры конфликтов для их разрешения.
3. **Отклонение / Откат**:
   - Просто удаляется или сбрасывается worktree. Основной репозиторий остается абсолютно нетронутым.

---

## 5. Обработка краевых случаев и фолбэки

| Краевой случай | Решение |
| :--- | :--- |
| **Рабочая область не под Git** | Если папка не является Git-репозиторием, происходит мягкий откат к прямым правкам файлов (с трекингом путей на уровне сессии, чтобы баннер отслеживал только файлы, записанные этой сессией). |
| **Сбой / Внезапное завершение** | При запуске приложения `AgentWorktreeManager.pruneOrphanedWorktrees` сканирует `.git/anydiff-worktrees/` и удаляет любые зависшие директории старше активного экземпляра приложения. |
| **Зависимости / Артефакты сборки** | Большинство инструментов сборки (`swift build`, `node_modules`, `target`) собираются внутри worktree. Для тяжелых `node_modules` можно использовать симлинк на основной репозиторий или настроить кеширование worktree. |
| **Пользователь редактирует основной репо во время работы агента** | 3-way слияние (`git apply --3way`) на этапе применения гарантирует, что изменения в основной ветке сохранятся и не будут перезаписаны вслепую. |

---

## 6. Этапы реализации

### Фаза 1: Базовый сервис `AgentWorktreeManager`
- [ ] Реализовать актор `AgentWorktreeManager` с методами `createWorktree`, `removeWorktree` и `pruneOrphanedWorktrees`.
- [ ] Добавить юнит-тесты, проверяющие создание, изоляцию, выполнение git-команд и очистку.

### Фаза 2: Подключение Session Manager
- [ ] Настроить `ACPAgentSessionManager` на запрос worktree при старте, если проект находится в Git-репозитории.
- [ ] Передавать путь worktree в качестве `cwd` для ACP-клиента.
- [ ] Направить `AgentGitChangesDetector` на работу в директории worktree.

### Фаза 3: UI просмотра и применения
- [ ] Обновить сценарий Review в `MainWindowView` для поддержки применения патчей из worktree обратно в основной репозиторий.
- [ ] Добавить контролы «Apply to Main Workspace» / «Discard» в шапку Review и карточки завершенных сообщений.
- [ ] Автоматическая очистка worktree при закрытии сессии.

### Фаза 4: Верификация и стресс-тестирование
- [ ] Запустить 2 живые сессии агентов параллельно.
- [ ] Проверить, что Агент 1 редактирует `FileA`, пока Агент 2 редактирует `FileB`.
- [ ] Убедиться, что баннеры, диффы вызовов инструментов и карточки ревью изолированы на 100% без каких-либо утечек.

---

## 7. Целевые метрики и производительность

| Метрика | Целевой показатель | Способ верификации |
| :--- | :--- | :--- |
| **Время создания worktree** | `< 250 мс` | Бенчмарк `AgentWorktreeManager.createWorktree` на репозиториях от 10 000 файлов. |
| **Расход дискового пространства** | `0 байт` (кроме изменённых файлов) | Проверка совместного использования `.git/objects` и паков без дублирования блобов. |
| **Время удаления worktree** | `< 100 мс` | Асинхронный `git worktree remove --force` при завершении сессии. |
| **Очистка зависших worktree** | `< 50 мс` на старте | Фоновое сканирование `.git/anydiff-worktrees/` при запуске AnyDiff. |

---

## 8. Инварианты безопасности и ограничение путей

1. **Контроль симлинков**: Предотвращение выхода агента за пределы песочницы worktree через относительные или битые симлинки.
2. **Нормализация путей в ACP**: Валидация всех запросов ACP файловых инструментов (`fs/read_text_file`, `fs/write_text_file`) со строгим ограничением внутри `worktreePath`.
3. **Изоляция переменных окружения подпроцессов**: Явная передача `GIT_WORK_TREE` и `GIT_DIR` в инструменты выполнения команд в терминале (`execute_command`), чтобы дочерние git-команды не задевали родительский рабочий каталог.
