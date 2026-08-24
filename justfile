set shell := ["zsh", "-cu"]

default:
    @just --list

# Run the app with Debug configuration.
dev path="":
    swift run -c debug AnyDiff {{path}}

# Run the app with Release optimizations.
release path="":
    swift run -c release AnyDiff {{path}}

# Build the optimized Release binary without running it.
build:
    swift build -c release

# Build the Debug binary without running it.
build-debug:
    swift build -c debug

# Attach to the running debug app and export a short text-readable profile.
trace:
    app_pid="$(pgrep -n -f '^\.build/arm64-apple-macosx/debug/AnyDiff( |$)' || true)"; \
    if [ -z "$app_pid" ]; then \
        printf 'No debug AnyDiff process found. Run: just dev .\n' >&2; \
        exit 1; \
    fi; \
    trace_file="/tmp/anydiff-scroll-$(date +%Y%m%d-%H%M%S).trace"; \
    xcrun xctrace record --no-prompt \
        --template 'Time Profiler' \
        --time-limit 20s \
        --output "$trace_file" \
        --attach "$app_pid" && \
    xcrun xctrace export \
        --input "$trace_file" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        --output "${trace_file%.trace}.xml" && \
    printf 'Trace: %s\nText:  %s\n' "$trace_file" "${trace_file%.trace}.xml"

# Remove Swift Package Manager build artifacts.
clean:
    swift package clean

# Clean and rebuild both Debug and Release configurations.
rebuild:
    just clean
    just build-debug
    just build

# Run fast unit tests in Debug configuration
test:
    swift test -c debug --filter AnyDiffCoreTests --skip Performance

# Run fast unit tests in Release configuration.
test-release:
    swift test -c release --filter AnyDiffCoreTests

# Run all regular tests in Debug configuration. Benchmarks are opt-in via `just bench`.
test-all:
    swift test -c debug

# Run heavy performance benchmarks in optimized Release configuration.
bench:
    ANYDIFF_RUN_BENCHMARKS=1 swift test -c release --filter AnyDiffBenchmarks

# Build Release and run the Release unit tests.
check:
    just build
    just test-release

# Package AnyDiff.app bundle, ZIP, and DMG for distribution to other Macs.
package:
    ./scripts/package_app.sh

# Alias for package
app:
    just package

# Package and deploy AnyDiff.app directly to the second Mac (mvpa).
deploy:
    just package
    scp dist/AnyDiff-macOS.zip dist/AnyDiff.dmg mvpa:~/Downloads/
    ssh mvpa "cd ~/Downloads && rm -rf AnyDiff.app && unzip -q AnyDiff-macOS.zip && xattr -cr AnyDiff.app"
    @echo "🚀 Deployed AnyDiff.app to second Mac ~/Downloads!"
