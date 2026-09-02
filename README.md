# AnyDiff

High-performance native macOS MultiBuffer Diff editor for lightning-fast code reviews and in-place editing in Swift.

![AnyDiff Overview](https://i.imgur.com/3bVQp8G.png)

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift)
![Build](https://img.shields.io/badge/build-passing-brightgreen?style=flat-square)
![Tests](https://img.shields.io/badge/tests-170%2B%20passing-brightgreen?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

Install via Homebrew:

```bash
brew install --cask vipmax/tap/anydiff
```

If macOS Gatekeeper prevents opening after installation:

```bash
xattr -cr /Applications/AnyDiff.app
```

Or download directly from [Releases](https://github.com/vipmax/anydiff/releases/latest) ([.dmg](https://github.com/vipmax/anydiff/releases/download/v1.1.1/AnyDiff.dmg) / [.zip](https://github.com/vipmax/anydiff/releases/download/v1.1.1/AnyDiff-macOS.zip)).

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
  - Supports opening ordinary local files as well as Git diffs.
  - Native support for GitHub Pull Requests, commit URLs, and compare links (`gh pr`, `https://github.com/.../pull/123`, `https://diffs.hub/...`).
  - Paste raw `.diff` / `.patch` files directly from the clipboard (`Cmd + Shift + V`).
- **Embedded AI Agent (ACP Protocol)**:
  - Native side panel for explaining diffs, reviewing code changes, generating commit messages, and running commands via JSON-RPC 2.0.
  - Multi-provider support: Codex, Claude Code, Gemini / Antigravity, and Custom ACP agents.
- **Rich Vector File Icons (Devicon SVGs)**: Crisp, high-resolution vector icons for 30+ major languages and configuration formats (TypeScript, React/TSX, JavaScript, Python, Rust, Go, Swift, Kotlin, Java, C++, C#, Docker, Git, SQL, Markdown, YAML, TOML, etc.) natively rendered via AppKit vector SVGs with 120 FPS caching.
- **Minimalist macOS Titlebar & Dark Themes**:
  - Curated themes: `Vesper` (Default), `macOS Dark`, `Tokyo Night`, `GitHub Dark`, `Zed Slate Gray`, `Zed Dark`, and `macOS Light`.
  - Tokenized syntax highlighting for Swift, Rust, TypeScript, JavaScript, Python, C++, Go, and JSON.

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
| **Cmd + Option + A** | Toggle the Codex Agent panel |

---

## 🤖 Embedded AI Agent (ACP Protocol)

AnyDiff includes a powerful native side panel powered by the **Agent Client Protocol (ACP)** over JSON-RPC 2.0. The agent operates directly within the context of the opened repository and diff, allowing you to review changes, explain complex logic, draft commit messages, generate code fixes, and run terminal commands seamlessly.

Toggle the panel anytime with **`Cmd + Option + A`**.

### 🌟 Key Capabilities

- **Multi-Provider Support & Presets**:
  - **OpenAI / Codex**: `@agentclientprotocol/codex-acp`
  - **Anthropic / Claude Code**: `@anthropic-ai/claude-code`
  - **Google Gemini / Antigravity**: Native Gemini CLI integration
  - **Custom ACP Agents**: Run any custom agent binary or command via stdio JSON-RPC
  - **Mock Mode**: Built-in offline simulator for rapid UI testing and demos
- **Visual Tool Call Cards**: Real-time visualization of agent actions — file reads, directory inspections, and bash commands with collapsible status cards.
- **Interactive File Changes & Diff Jumps**: The **Edited Files Card** displays all files modified by the agent during the conversation, allowing you to jump directly to specific file diffs in the editor.
- **Multimodal Image Attachments**: Drag-and-drop or paste images/screenshots directly into the chat prompt with live thumbnails and a full-screen zoomable preview modal (`AgentZoomableImageView`).
- **Streaming Reasoning & Thoughts**: Real-time rendering of model thinking processes with customizable reasoning effort level controls (Low / Medium / High).
- **Token & Context Usage Gauge**: Live tracking of prompt/completion tokens and context window capacity.
- **Session History & Saved Chats Drawer**: Automatically saves conversation threads per workspace; seamlessly switch between, rename, or resume past agent sessions.
- **Quick-Action Presets**: One-click prompts to *Explain Diff*, *Review Changes*, and *Generate Commit Message*.
- **Granular Permissions & Safety**: Client-side approval prompts for disk writes and terminal commands before any modifications are executed.

### ⚙️ Architecture

The ACP integration is built natively in `AnyDiffCore` and `AnyDiffUI`:
- **`ACPTransport`**: Manages the child agent process lifecycle, streaming JSON-RPC payloads over `stdin`/`stdout` and capturing diagnostics on `stderr`.
- **`ACPClient`**: Handles JSON-RPC 2.0 protocol handshakes, capability negotiation, prompt dispatch, cancellation, tool execution callbacks, and filesystem permission requests.
- **`ACPAgentSessionCoordinator`**: Bridges protocol events directly to the high-performance SwiftUI / AppKit chat feed.

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
│   │   ├── Review/           # ReviewManager, ReviewComment
│   │   ├── ACP/              # JSON-RPC 2.0 / Agent Client Protocol transport and models
│   │   └── Agent/            # Agent session state, ACP manager, and mock implementation
│   ├── AnyDiffUI/            # Native presentation layer (SwiftUI + custom AppKit CoreText engine)
│   │   ├── Editor/           # CustomMultiBufferEditorView, ExcerptLayout, LineCache, Virtual Scroll
│   │   ├── Agent/            # Chat panel, Markdown rendering, input, and tool-call cards
│   │   └─ Views/            # MainWindowView, SidebarFileListView, FileIconProvider, Icons, Modals
│   └─ AnyDiff/              # Application entry point (main.swift, AppDelegate)
└── Tests/
    └─ AnyDiffCoreTests/     # Comprehensive unit & AppKit UI integration test suites (170+ tests)
```

---

## 💻 CLI Usage

Once installed, launch AnyDiff from your terminal anywhere:
```bash
anydiff .                      # Open diff for the current repository
anydiff ~/dev/my-project       # Open diff for a specific directory
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
