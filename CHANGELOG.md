# Changelog

All notable changes to **AnyDiff** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.2.0] - 2026-09-03

### 🔍 Full-Text Project Search & Streaming MultiBuffer
- **High-Performance Search Engine (`ProjectSearchEngine`)**:
  - Full-text search across entire repository with regex (`.*`), match whole word (`\b`), case sensitivity (`Aa`), and glob include/exclude filters.
  - Automatic filtering of binary files (null byte scan) and files over size threshold.
  - Multi-encoding fallback support (UTF-8, Latin-1 / ISO-8859).
- **Streaming Delivery & Context Clustering**:
  - Progressive batch streaming delivering initial search matches immediately without waiting for full directory scan.
  - Intelligent context clustering with configurable padding lines merging nearby matches into single excerpts.
  - $O(1)$ lazy MultiBuffer slicing and in-memory match recalculation during live typing.
- **Native Search Bar UI & Navigation**:
  - AppKit/SwiftUI `ProjectSearchBarView` with keyboard navigation: `Cmd + F` (find in project), `Cmd + Shift + F` (find with prefilled selection), `Cmd + G` (next match), `Cmd + Shift + G` (previous match), `Esc` (dismiss).
  - Search hit counter, active match pulsing, and instant match jump navigation.
  - Integrated into the main macOS application menu.

### 🌐 Unicode & Internationalization
- Full international path, Cyrillic, and multi-scalar emoji selection support across virtualized editor.

### 🧪 Tests
- Expanded test suite to **208 passing unit & integration tests**.

---

## [1.1.1] - 2026-09-02

### 🐛 Bug Fixes
- **Packaging & Gatekeeper**:
  - Fixed startup crash in release builds caused by missing SwiftPM resource bundle (`AnyDiff_AnyDiffUI.bundle`) in `AnyDiff.app/Contents/Resources`.
  - Added resilient multi-path bundle resolution with safe fallbacks in `Icons.swift`.
  - Added macOS Gatekeeper quarantine removal instructions in README.

---

## [1.1.0] - 2026-09-02

### 🤖 Embedded AI Agent (ACP Protocol)
- **Agent Client Protocol (JSON-RPC 2.0)**:
  - Added native embedded side panel (`Cmd + Option + A`) supporting full agent lifecycle over stdio JSON-RPC.
  - Multi-provider presets: OpenAI / Codex, Anthropic / Claude Code, Google Gemini / Antigravity CLI, and Custom ACP Agent commands.
  - Offline Mock Mode for rapid UI iteration and testing without external processes.
- **Multimodal Image Attachments & Zoom Preview**:
  - Drag-and-drop or clipboard paste (`Cmd + V`) of screenshots into prompts.
  - Live attachment thumbnails and full-screen zoomable modal view (`AgentZoomableImageView`).
- **Interactive Tool Call & Diff Jumps**:
  - Real-time expandable tool call cards for file reads, directory listings, and bash commands.
  - **Edited Files Card**: live tracking of files modified by the agent with instant jumps to specific file diffs in the multi-buffer editor.
- **Reasoning & State Management**:
  - Streaming thinking thoughts and customizable reasoning effort levels (Low / Medium / High).
  - Context & token usage gauge with live capacity tracking.
  - Saved chat session history drawer per workspace with thread switching, renaming, and persistence.
  - Granular client-side permissions for disk writes and terminal command executions.

### 🎨 Rich Vector File Icons (Devicon SVGs)
- **30+ Devicon Brand Vector Icons**:
  - High-resolution SVG vector icons for TypeScript, React/TSX, JavaScript, Python, Rust, Go, Swift, Kotlin, Java, C++, C#, Docker, Git, SQL, Markdown, YAML, TOML, GraphQL, Shell, and more.
  - Zero-dependency AppKit SVG rendering with `NSCache` for 120 FPS scrolling performance.

### ⚡ WordDiff & Display Engine Optimizations
- Added intra-line word diff render caching (`WordDiffRenderCache`) for instant zero-copy hunk display.
- Enhanced Cyrillic and international UTF-8 intra-line Myers diff highlighting.
- Expanded test suite to **176 passing tests**.

---

## [1.0.1] - 2026-08-18

### 🚀 Mega-Diff & 1M+ Lines Memory Optimization
- **Ultra-Low Memory Footprint (~250 MB on 1M+ LOC PRs)**:
  - Validated on Bun's mega pull request (`41.3 MB diff`, `2,188 files`, `1,029,583 lines of code`).
  - Active memory consumption reduced to **~250 MB** RSS (compared to **~2.2 GB** in Zed and standard diff viewers — **~9x less RAM**).
  - No memory leaks or runaway growth during extreme scrolling across 1,000,000+ lines.

### ⚡ 64 KB SIMD Streaming Git Diff Parser
- **18x Faster Time-To-First-File (TTFF)**:
  - Subprocess streaming through `GitStreamReader` and 64 KB `ChunkLineSplitter` delivers the initial UI frame in **~400 ms** while `git diff` continues reading in the background.
- **5.5x Parser Throughput**:
  - Vectorized contiguous byte scanning processes **>950,000 diff lines/sec** (>38 MB/s).

### 📦 Low-Level CPU Register & Cache Line Packing
- **8-Byte Coordinate Structures**:
  - `MultiBufferPoint` & `BufferPoint` compressed from 16 bytes to **8 bytes** (`Int32` storage with `@inlinable` `Int` accessors).
  - Passes in a single 64-bit ARM64 CPU register (`x0`), eliminating register spilling and stack allocation during high-frequency cursor/selection operations.
- **Virtual Range Index Packed to 33 Bytes**:
  - `DisplayMap.ExcerptSliceRange` compressed from 96 bytes to **33 bytes** (`stride`: 36 bytes) with `ExcerptFlags: OptionSet`.
  - Fits inside half of a single 64-byte L1 CPU Cache Line, significantly accelerating $O(\log N)$ binary search coordinate translations.

### 🧠 Intra-Line WordDiffEngine (L1-Cache LCS & Zero Heap Allocations)
- **40 KB L1-Cache LCS Matrix**:
  - LCS dynamic programming matrix converted to a flat 1D stack-allocated `[UInt8]` buffer (`withUnsafeTemporaryAllocation`).
  - Working memory shrunk from **323 KB to 40.4 KB** (an **8x reduction**), ensuring 100% data locality inside the Apple Silicon L1 Data Cache.
- **Zero-Allocation UTF-8 Pointer Tokenization**:
  - Replaced `Array(text)` with direct contiguous UTF-8 pointer iteration (`withContiguousStorageIfAvailable`), eliminating heap allocations per tokenized code line.

### 🏎️ Smooth 120 FPS ProMotion Viewport Virtualization
- **Virtual Line Synthesis**:
  - Removed flat line arrays in favor of on-demand viewport synthesis from `ExcerptSliceRange` prefix sums.
  - Achieved simulated **465+ FPS** during rapid scrolling across 1,000,000+ line diffs with instantaneous frame times.

### 🧪 Benchmarks & Tests
- Expanded automated test suite to **56 passing unit & integration tests**.
- Added dedicated `MemoryPackingBenchmarkTests` suite for continuous memory layout and micro-benchmark verification.

---

## [1.0.0] - 2026-08-16

### 🎉 Initial Release
- MultiBuffer architecture for multi-file Git diffs and PR reviews.
- Native AppKit & CoreText high-performance rendering engine.
- Safe in-place editing with disk auto-save and file change tracking.
- Context folding, excerpt expansion, and sticky headers.
- GitHub Pull Request, commit, and compare URL loading.
- Inline review comments and tokenized syntax highlighting.
