# Timeline Panel & Local History Architecture Plan

## 1. Objective

Provide AnyDiff with an automatic, non-destructive **Timeline & Local History** system ("Time Machine for Repositories") that records granular project states over time.

While `Git History` only records explicit `git commit` checkpoints, the **Timeline Panel** captures the active, continuous pulse of development:
1. **External Watcher events** (file changes from Xcode, VS Code, Cursor, CLI scripts, build tools).
2. **In-app manual edits** performed directly inside AnyDiff's editor/MultiBuffer.
3. **AI Agent tool actions** (modifications via ACP `client_edit_file` / `client_create_file`).
4. **Git lifecycle events** (branch checkouts, stashes, merge/rebase steps, commits).
5. **Manual Checkpoints** (user-initiated bookmarks/snapshots before risky refactorings).

Developers can scrub through time, compare any snapshot against the current working copy or another snapshot, view single-file evolution, and safely revert changes at the file or project level.

---

## 2. Storage Architecture: Shadow Git Trees (CAS)

Copying the entire project directory on every edit would rapidly exhaust disk space. Instead, AnyDiff will leverage **Content-Addressable Storage (CAS)** through Git's low-level plumbing.

### 2.1 Isolated Shadow Index & Refs

To capture working directory state without interfering with the user's active `.git/index` or working branches:

1. **Custom Index File (`GIT_INDEX_FILE`)**:
   Snapshot operations write into a dedicated index file (e.g. `.git/anydiff_timeline_index` or inside application cache `~/.anydiff/timeline/<repo-id>/index`), leaving `.git/index` untouched.
2. **Plumbing Flow**:
   ```bash
   # 1. Populate isolated index with current working directory (respecting .gitignore)
   GIT_INDEX_FILE=.git/anydiff_timeline_index git add -A

   # 2. Write tree object (deduplicated by SHA-1 / SHA-256)
   tree_sha=$(GIT_INDEX_FILE=.git/anydiff_timeline_index git write-tree)

   # 3. Create lightweight shadow commit object
   commit_sha=$(git commit-tree $tree_sha -p $prev_snapshot_sha -m "Timeline: <source>")

   # 4. Store under AnyDiff-private ref namespace
   git update-ref refs/anydiff/timeline/<snapshot-uuid> $commit_sha
   ```
3. **Benefits**:
   - **Zero redundancy**: Git naturally deduplicates unmodified files. A snapshot modifying 1 file only creates 1 new blob and small tree nodes.
   - **Native Diff Performance**: Diffing any snapshot against the working tree, HEAD, or another snapshot is instantly computed via `git diff-tree` / `git diff`.
   - **Clean Namespace**: `refs/anydiff/*` are invisible to standard `git log`, `git branch`, and remote operations (`git push` ignores them).

### 2.2 Metadata Database (Catalog)

While Git stores content trees, snapshot metadata is kept in an indexed catalog (`SQLite` or structured `JSONL` manifest in `.git/anydiff/timeline.db`) for instant UI rendering without scanning thousands of git refs:
- Snapshot UUID, timestamp, parent UUID.
- Trigger source (`watcher`, `manualEditor`, `agent`, `git`, `manualCheckpoint`).
- List of changed relative file paths, addition/deletion stats.
- Commit hash / tree hash.
- User annotation / note (if checkpoint).

---

## 3. Event Sources & Coalescing Engine (Debouncer)

High-frequency file system events (e.g., during `npm install`, `swift build`, or fast typing) must be coalesced to avoid creating thousands of redundant snapshots.

```
┌─────────────────┐
│  FolderWatcher  │────┐
└─────────────────┘    │
┌─────────────────┐    │     ┌────────────────────────┐      ┌─────────────────────────┐
│ In-Editor Save  │────┼────▶│ TimelineEventDebouncer │─────▶│ SnapshotCreationPipeline│
└─────────────────┘    │     │  - 1.5s Quiescence     │      │  - Filter .gitignore    │
┌─────────────────┐    │     │  - 15s Latency Ceiling │      │  - Size threshold       │
│ Agent Execution │────┤     └────────────────────────┘      │  - Git CAS commit-tree  │
└─────────────────┘    │                                     └─────────────────────────┘
┌─────────────────┐    │
│ Manual Bookmark │────┘
└─────────────────┘
```

### 3.1 Coalescing Rules
- **Quiescence Window (Idle timer)**: 1.5 seconds of silence after the last event before sealing a snapshot.
- **Latency Ceiling**: If edits are continuous (e.g., non-stop typing in editor), force a snapshot after at most 15 seconds to avoid losing intermediate history.
- **Ignore Rules**:
  - Automatically honor `.gitignore`.
  - Hard-ignore `.git/`, `.build/`, `DerivedData/`, `node_modules/`, `.DS_Store`, and temporary editor swap files (`.swp`, `*~`).
  - Ignore binary files exceeding a configurable size threshold (default: 10 MB).

---

## 4. Data Models (`AnyDiffCore/Timeline`)

```swift
import Foundation

public struct TimelineSnapshot: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let source: TimelineSource
    public let treeHash: String
    public let commitHash: String
    public let changedFiles: [TimelineFileChange]
    public let totalAdditions: Int
    public let totalDeletions: Int
    public let note: String?
}

public struct TimelineFileChange: Codable, Sendable, Hashable {
    public let relativePath: String
    public let changeType: ChangeType // .added, .modified, .deleted
    public let additions: Int
    public let deletions: Int
}

public enum TimelineSource: Codable, Sendable {
    case watcher(fileCount: Int)
    case manualEditor(filePath: String)
    case agent(taskDescription: String)
    case git(action: String) // e.g. "Commit 7a3f1c", "Checkout main"
    case checkpoint(name: String)
}

public enum TimelineFilterScope: Hashable, Sendable {
    case allProject
    case singleFile(relativePath: String)
}
```

---

## 5. UI & UX Architecture (`AnyDiffUI`)

### 5.1 Panel Integration

Add `case timeline` to `PanelContent`:

```swift
public enum PanelContent: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case changes
    case files
    case history
    case timeline   // <-- New panel: "Timeline", icon: "clock.arrow.circlepath"
    case editor
    case agent
}
```

This allows placing the Timeline panel in any slot (left sidebar, right inspector, or bottom drawer).

### 5.2 Timeline Panel Layout

1. **Toolbar & Filter Bar**:
   - Scope Switcher: **All Project** vs **Current File** (automatically follows whichever file is active in the diff viewer).
   - Source Filters: Buttons to toggle `Watcher`, `Editor`, `Agent`, `Git`, `Bookmarks`.
   - "New Checkpoint" button (`⌘⇧S`) to capture an immediate named point in time.
2. **Chronological Stream**:
   - Grouped by relative time sections ("Just now", "10 minutes ago", "Earlier today", "Yesterday").
   - Event row with:
     - Timestamp (`14:22:05`).
     - Badge / Icon denoting the origin (`FolderWatcher`, `AnyDiff Editor`, `Agent`, `Git`).
     - Summary label (e.g. `FolderWatcher: 3 files changed` or `Agent: client_edit_file`).
     - Diff metrics (`+24`, `-10`).
     - Compact horizontal pills of affected filenames.
3. **Inspector & Diff Viewing**:
   - Clicking a snapshot activates **Comparison Mode**:
     - **Snapshot ↔ Working Copy** (Shows what would be undone if reverted).
     - **Snapshot ↔ Previous Snapshot** (Shows incremental change at that moment).
   - Selecting two snapshots via `⌘ + Click` displays a range diff between any two arbitrary points in time.
4. **Restoration Controls**:
   - **Revert Entire Project**: Restores all files in working directory to match the snapshot tree.
   - **Restore File**: Reverts only the selected file from the snapshot, leaving other working changes intact.
   - **Create Git Branch / Commit**: Elevates a timeline snapshot into an official Git commit or branch.

---

## 6. Retention Policy & Garbage Collection

To ensure disk usage stays bounded:

1. **Decay Schedule**:
   - **< 2 hours**: Snapshots preserved at high resolution (every ~1-2 minutes of activity).
   - **2 hours to 48 hours**: Intermediate minor snapshots consolidated into 15-30 minute intervals.
   - **2 days to 30 days**: Only manual checkpoints, agent boundaries, and major milestones preserved.
   - **> 30 days**: Automatically pruned (configurable in Settings).
2. **Storage Quota**:
   - Configurable size cap (e.g., maximum 500 MB per repository).
   - Once quota is reached, oldest non-checkpoint snapshots are evicted first.
3. **Pruning Process**:
   - Delete corresponding `refs/anydiff/timeline/<id>` references.
   - Run `git prune --expire=now` (targeting only unreferenced objects in shadow namespace) during idle application state or workspace close.

---

## 7. Phased Implementation Roadmap

### Phase 1: Core Shadow Git Engine (`AnyDiffCore/Timeline`)
- Implement `TimelineStorageEngine` using Git plumbing commands with isolated `GIT_INDEX_FILE`.
- Implement `writeSnapshot(source:files:note:)` producing tree/commit objects.
- Implement `readDiff(snapshotId:toTarget:)` bridging into existing `GitDiffParser`.
- Add unit tests for snapshot creation, deduplication, and diff generation.

### Phase 2: Debouncer & Event Ingestion (`TimelineCoordinator`)
- Hook `TimelineCoordinator` into `FolderWatcher` in `MainWindowView`.
- Hook in-app edit/save notifications from `MultiBuffer` / `CustomMultiBufferEditorView`.
- Hook ACP agent tool lifecycle (`onToolExecutionCompleted`).
- Implement quiescence timer (1.5s) and latency ceiling (15s).

### Phase 3: Timeline UI Panel (`AnyDiffUI/Timeline`)
- Add `PanelContent.timeline` and create `TimelinePanelView.swift`.
- Build the virtualized timeline list with source icons, diff stats, and time headers.
- Implement file-scoped vs repository-scoped toggle.
- Integrate selection with `DiffContainerView` to display snapshot diffs seamlessly.

### Phase 4: Revert, Branching & Retention
- Add "Restore File" and "Revert Project to Snapshot" actions with confirmation dialogs.
- Add "Bookmark / Checkpoint" dialog (`⌘⇧S`).
- Implement background retention manager and LRU garbage collection.
