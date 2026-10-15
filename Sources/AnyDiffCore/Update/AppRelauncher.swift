import Foundation

/// Replaces the running app after it quits and opens it again.
/// A helper process does the swap, because the app cannot overwrite its own bundle while it runs.
public enum AppRelauncher {
    /// Run as `sh -c script sh <pid> <app path> <staging dir>`. An empty staging dir only reopens the app.
    /// The old bundle is kept until the new one is in place, so a failed copy leaves the app as it was.
    static let script = """
    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
    if [ -n "$3" ]; then
        rm -rf "$2.updating" "$2.previous"
        if ditto "$3/AnyDiff.app" "$2.updating" && mv "$2" "$2.previous"; then
            if mv "$2.updating" "$2"; then rm -rf "$2.previous"; else mv "$2.previous" "$2"; fi
        fi
        rm -rf "$3" "$2.updating"
    fi
    open "$2"
    """

    /// The helper process, not yet started. It waits for `pid` to exit before swapping and reopening.
    public static func makeHelper(
        replacing appBundleURL: URL,
        stagingDirectory: URL?,
        afterExitOf pid: Int32
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), appBundleURL.path, stagingDirectory?.path ?? ""]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }
}
