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
    swift test -c debug --filter AnyDiffCoreTests

# Run fast unit tests in Release configuration.
test-release:
    swift test -c release --filter AnyDiffCoreTests

# Run all tests (including benchmarks) in Debug configuration.
test-all:
    swift test -c debug

# Run heavy performance benchmarks in optimized Release configuration.
bench:
    swift test -c release --filter AnyDiffBenchmarks

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


