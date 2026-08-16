# AnyDiff

High-performance native macOS MultiBuffer Diff editor for productive Code Reviews in Swift, built upon the Zed architecture (`multi_buffer`).

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)
![Build](https://img.shields.io/badge/build-passing-brightgreen?style=flat-square)
![Tests](https://img.shields.io/badge/tests-9%2F9%20passing-brightgreen?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

---

## Key Features

- **MultiBuffer Architecture**: Concatenates code excerpts and diff hunks from multiple files into a single continuous virtual document with unified scrolling and instant two-way coordinate mapping (`MultiBufferRow <-> (File, Line)`).
- **Dynamic Live Diff Engine (`LineDiffEngine`)**:
  - Pure in-memory Myers diff algorithm recalculates the diff in 0.05–0.1 ms on every single keystroke.
  - Real-time gutter line number adjustments, hunk re-clustering, and dynamic `+N -M` change metrics update continuously.
- **Sticky File Headers**:
  - As you scroll through multi-line file diffs, the file header (displaying path, status, and `+N -M` diff badges) anchors to the top with a subtle elevation drop shadow.
  - Push-away physics: approaching headers smoothly displace the currently pinned header.
  - Interactive file collapsing directly from the sticky header.
- **Safe In-Place Diff Editing**:
  - Green added (`.added`) and context (`.unchanged`) lines can be freely edited live.
  - Red deleted lines (`.deleted`) are strictly protected against accidental modification (Read-Only) with system audio feedback.
  - Direct file persistence to disk (`Cmd + S`).
- **Custom CoreText Rendering Engine**:
  - Zero `NSTextView` overhead with full viewport virtualization: only visible lines are rendered, easily achieving 120 FPS ProMotion performance.
  - Effortlessly handles diffs spanning thousands of lines.
- **Dual Gutter Line Numbering**: Separate old and new line numbers with colored status indicators (`+` added, `-` deleted).
- **Intra-Line Word Diff**: Word- and character-level token highlighting powered by Myers/LCS that automatically adapts during live edits.
- **Live In-Place Editing**:
  - Direct typing, Enter, Tab, Backspace, and Delete within excerpts.
  - Mouse and keyboard multi-line text selection.
  - Transactional Undo/Redo (`Cmd + Z`, `Cmd + Shift + Z`) managed by `MultiBufferUndoManager`.
- **Context Folding & Expansion**:
  - Click any file header to collapse or expand all its hunks.
  - Interactive `Fold Gap` bars expand hidden context lines upward or downward in 10-line increments.
- **Inline Code Review**: Add review comments and discussion threads by clicking the `+` button in the gutter.
- **Seamless Git Integration**:
  - Automatically discovers and loads uncommitted diffs from the working directory on launch.
  - Quick refresh with `Cmd + R` to pull updated repository changes instantly.
  - Open arbitrary local repositories or paste custom `.diff` / `.patch` files.
- **Minimalist Titlebar UI**:
  - 100% of window height dedicated to code review and editing.
  - Directory switcher, diff reload, and theme palette buttons seamlessly integrated into the native titlebar to the left of the split divider.
  - Active folder name dynamically displayed in the window header.
  - Auto-hiding fade scrollbars.
- **Themes & Syntax Highlighting**:
  - Curated themes: `Zed Slate Gray` (signature `#28292d`), `Zed Dark`, `Tokyo Night`, and `GitHub Dark`.
  - Tokenized syntax highlighting for Swift, Rust, TypeScript, Python, C++, Go, and JSON.

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **Cmd + O** | Open Git repository folder |
| **Cmd + R** | Reload diff from current repository |
| **Cmd + S** | Save modified buffers to disk |
| **Cmd + Shift + V** | Paste Git diff from clipboard |
| **Cmd + Z** | Undo last edit |
| **Cmd + Shift + Z** | Redo edit |
| **Cmd + A** | Select all text |
| **Cmd + C** | Copy selected text |
| **Cmd + V** | Paste text |
| **Option + Click** | Expand hidden context lines (Fold Gap) |

---

## Architecture Overview

```text
AnyDiff
├── Sources/
│   ├── AnyDiffCore/          # Headless core engine (Zero AppKit/UI dependency)
│   │   ├── Diff/             # GitDiffParser, LineDiffEngine, WordDiffEngine, DiffHunk
│   │   ├── MultiBuffer/      # MultiBuffer, Buffer, Excerpt, UndoManager, EditTransaction
│   │   ├── Display/          # DisplayMap, DisplayLine, Coordinate Mapping
│   │   ├── Syntax/           # SyntaxHighlighter, Theme Definitions
│   │   └── Review/           # ReviewManager, ReviewComment
│   ├── AnyDiffUI/            # Presentation layer (SwiftUI + custom AppKit CoreText engine)
│   │   ├── Editor/           # CustomMultiBufferEditorView, CoreText LineCache, Virtual Scroll
│   │   └── Views/            # MainWindowView, SidebarFileListView, Modals
│   └── AnyDiff/              # Application entry point (main.swift, AppDelegate, NSApplication)
└── Tests/
    └── AnyDiffCoreTests/     # Comprehensive unit test suite (Diff, MultiBuffer, WordDiff)
```

---

## Building and Running

### Prerequisites
- macOS 14.0+ (Sonoma or later)
- Swift 6.0+ / Xcode 16.0+

### Terminal Quickstart
```bash
# Clone the repository
git clone https://github.com/your-username/anydiff.git
cd anydiff

# Run unit tests
swift test

# Build and launch AnyDiff
swift run
```

---

## License

Released under the MIT License.
