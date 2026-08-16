set shell := ["zsh", "-cu"]

default:
    @just --list

# Run the app with Debug configuration.
dev:
    swift run -c debug

# Run the app with Release optimizations.
release:
    swift run -c release

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

# Run the test suite in Debug configuration.
test:
    swift test -c debug

# Run the test suite in Release configuration.
test-release:
    swift test -c release

# Build Release and run the Release tests.
check:
    just build
    just test-release
