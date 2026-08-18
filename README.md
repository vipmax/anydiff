# AnyDiff

High-performance native macOS MultiBuffer Diff editor for lightning-fast code reviews and in-place editing in Swift, built upon the Zed architecture (`multi_buffer`).

![AnyDiff Overview](https://i.imgur.com/SgdOxs2.png)

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)
![Build](https://img.shields.io/badge/build-passing-brightgreen?style=flat-square)
![Tests](https://img.shields.io/badge/tests-56%2F56%20passing-brightgreen?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

---

## 🚀 Key Features

- **MultiBuffer Architecture**: Concatenates code excerpts and diff hunks from multiple files into a single continuous virtual document with unified scrolling and instant two-way coordinate mapping (`MultiBufferPoint <-> (BufferId, BufferPoint)`).
- **Safe In-Place Diff Editing**:
  - Green added (`.added`) and context (`.unchanged`) lines can be edited directly in real time.
  - Red deleted lines (`.deleted`) are protected against accidental modifications with system audio feedback.
  - Real-time disk persistence (`Cmd + S`) and debounced auto-saving.
- **Sticky File Headers & Collapsing**:
  - Pinned file headers stick to the top as you scroll through lengthy diffs with subtle elevation drop shadows and smooth push-away physics.
  - Interactive file collapsing/expanding directly from the sticky or inline headers with robust `filePath` targeting.
- **Context Folding & Smooth Expansion**:
  - Expand hidden context lines upward or downward in 5-line or full-file increments.
  - Adjacent excerpts seamlessly merge upon meeting boundaries.
- **Intra-Line Word Diff**: High-precision token- and character-level highlighting powered by Myers LCS with common prefix/suffix pruning.
- **Inline Code Review**: Add threaded review comments and notes on any line.
- **Multi-Source Git & Web Integration**:
  - Automatically loads uncommitted diffs from any local repository.
  - Native support for GitHub Pull Requests, commit URLs, and compare links (`gh pr`, `https://github.com/.../pull/123`, `https://diffs.hub/...`).
  - Paste raw `.diff` / `.patch` files directly from the clipboard (`Cmd + Shift + V`).
- **Minimalist macOS Titlebar & Dark Themes**:
  - Curated themes: `Zed Dark`, `Unified Dark`, `Tokyo Night`, `GitHub Dark`, and `Monokai Pro`.
  - Tokenized syntax highlighting for Swift, Rust, TypeScript, JavaScript, Python, C++, Go, and JSON.

---

![AnyDiff MultiBuffer Editing](https://i.imgur.com/5Oq71Iy.png)

---

## ⚡ Performance Highlights

- **1,000,000+ Lines in Seconds**: Opens massive multi-file diffs (2,000+ files, 1M+ lines) in 1–2 seconds where other editors freeze, run out of memory, or drop frames.
- **Pure 120 FPS ProMotion Virtualization**: Built entirely on native AppKit and CoreText without WebViews or Electron layers. Only visible lines are rendered on screen.
- **Hierarchical `ExcerptLayout`**: $O(\log M)$ 2-level binary search layout engine (~15 ops, <15 ns lookup). No flat million-element coordinate arrays in memory.
- **$O(\text{File Lines})$ Incremental Myers Diff Engine**: Keystrokes, text insertions, and newlines (`\n`) recalculate diffs only for the active excerpt in <0.1 ms without touching unrelated files.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **Cmd + O** | Open Git repository folder |
| **Cmd + R** | Reload diff from current repository |
| **Cmd + S** | Save modified buffers to disk |
| **Cmd + Shift + V** | Paste Git diff / PR URL from clipboard |
| **Cmd + Z** | Undo last edit |
| **Cmd + Shift + Z** | Redo edit |
| **Cmd + A** | Select all text |
| **Cmd + C** | Copy selected text |
| **Cmd + V** | Paste text |
| **Option + Click** | Expand all hidden context lines |

---

## 🏗️ Architecture Overview

```text
AnyDiff
├── Sources/
│   ├── AnyDiffCore/          # Headless core engine (Zero UI / AppKit dependency)
│   │   ├── Diff/             # GitDiffParser, LineDiffEngine, WordDiffEngine, GitHubDiffService
│   │   ├── MultiBuffer/      # MultiBuffer, Buffer, Excerpt, UndoManager, EditTransaction
│   │   ├── Display/          # DisplayMap, DisplayLine, Coordinate Mapping
│   │   ├── Syntax/           # SyntaxHighlighter, Theme Definitions
│   │   └── Review/           # ReviewManager, ReviewComment
│   ├── AnyDiffUI/            # Native presentation layer (SwiftUI + custom AppKit CoreText engine)
│   │   ├── Editor/           # CustomMultiBufferEditorView, ExcerptLayout, LineCache, Virtual Scroll
│   │   └── Views/            # MainWindowView, SidebarFileListView, Modals
│   └── AnyDiff/              # Application entry point (main.swift, AppDelegate)
└── Tests/
    └── AnyDiffCoreTests/     # Comprehensive unit & AppKit UI integration test suites (39 tests)
```

---

## 📦 Installation

### One-Line Install (macOS)

```bash
# Via GitHub CLI (for private/authorized access)
gh release download v1.0.0 -R vipmax/anydiff -p "AnyDiff-macOS.zip" -O - | tar -x -C /Applications && xattr -cr /Applications/AnyDiff.app

# Or run the install script:
gh api repos/vipmax/anydiff/contents/scripts/install.sh -H "Accept: application/vnd.github.raw" | bash
```

Once installed, use the CLI anywhere:
```bash
anydiff .                      # Open diff in current git repo
anydiff ~/dev/my-project       # Open specific project
```

---

## 🛠️ Building and Running from Source

### Prerequisites
- macOS 14.0+ (Sonoma or later)
- Swift 6.0+ / Xcode 16.0+
- [just](https://github.com/casey/just) (optional, for convenience commands)

### Quickstart

```bash
# Clone the repository
git clone https://github.com/vipmax/anydiff.git
cd anydiff

# Run all unit and UI integration tests
swift test

# Run development build on current directory or any local repo
just dev .
# or
just dev ~/dev/my-project

# Build optimized production release binary
just build
# or run production build
just release ~/dev/my-project
```

---

## 📄 License

Released under the MIT License.
