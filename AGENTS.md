# Repository Guidelines

## Project Structure & Module Organization

AnyDiff is a native macOS Swift Package Manager app.

- `Sources/AnyDiffCore/` contains UI-independent diff, Git, watcher, editing, syntax, display, and MultiBuffer logic.
- `Sources/AnyDiffUI/` contains SwiftUI/AppKit views and the custom virtualized editor.
- `Sources/AnyDiff/` contains the executable entry point and app-level wiring.
- `Tests/AnyDiffCoreTests/` contains XCTest unit and editor integration tests; `Tests/AnyDiffBenchmarks/` contains performance tests.
- `Resources/` stores icons and asset catalogs. `scripts/` builds `.app`, ZIP, and DMG packages.
- `Package.swift` defines the macOS 13 deployment target; `justfile` provides common workflows.

Keep reusable behavior in `AnyDiffCore`; avoid introducing AppKit or SwiftUI dependencies there.

## Build, Test, and Development Commands

Run from the repository root:

```bash
just dev .                 # Run the debug app against the current directory
just build                 # Build the optimized release binary
just build-debug           # Build the debug binary
just test                  # Run the fast AnyDiffCoreTests suite
just test-all              # Run all tests, including benchmarks
just bench                 # Run benchmarks in release configuration
just check                 # Build release and run release unit tests
just package               # Create dist/AnyDiff.app, ZIP, and DMG artifacts
```

Use `swift test --filter AnyDiffCoreTests.SomeTest` to target one test; `just clean` removes SwiftPM artifacts.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, clear type-driven names, and explicit access control where useful. Use `UpperCamelCase` for types and `lowerCamelCase` for methods, properties, and locals. Name XCTest methods `test...` descriptively. Group files by feature and keep UI code out of core modules. No formatter or linter is configured; preserve surrounding formatting and build after mechanical edits.

## Testing Guidelines

Tests use XCTest. Add regression coverage for parser, diff, editing, watcher, and UI changes in the matching test file. Run `just test` during iteration and `just test-all` before performance-related changes. Network-dependent GitHub tests are skipped unless their environment flag is enabled. No coverage threshold is configured.

## Commit & Pull Request Guidelines

Use concise imperative commits with the established prefixes, optionally scoped: `feat(watcher): reload after branch switch` or `fix(ui): preserve scroll anchor`. Keep unrelated changes separate. Pull requests should explain impact, link an issue when applicable, list validation commands, and include screenshots or recordings for UI changes. Call out macOS, filesystem, Git, or performance assumptions.

## Security & Configuration Tips

Do not commit credentials, GitHub tokens, generated `dist/`, or `.build/` output. Treat live network tests and packaging/deployment commands as environment-dependent; review targets before running them.
