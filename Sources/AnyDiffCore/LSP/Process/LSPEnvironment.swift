import Foundation

/// Centralized resolution of host toolchains, executables, and execution environments.
public enum LSPEnvironment {

    /// Returns standard search directories for discovering binaries across macOS and user package managers.
    public static var searchPaths: [String] {
        var paths: [String] = []

        // 1. Inherit from current process PATH
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: envPath.components(separatedBy: ":"))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 2. Standard macOS package manager and user paths
        let standardPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.dotnet/tools",
            "\(home)/.bun/bin",
            "\(home)/.zerobrew/bin",
            "\(home)/.local/bin"
        ]
        for p in standardPaths where !paths.contains(p) {
            paths.append(p)
        }

        // 3. Scan nvm node versions if present
        let nvmNodeDir = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        if let nvmVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmNodeDir.path) {
            for ver in nvmVersions.sorted().reversed() {
                let binDir = nvmNodeDir.appendingPathComponent(ver).appendingPathComponent("bin").path
                if FileManager.default.fileExists(atPath: binDir) && !paths.contains(binDir) {
                    paths.append(binDir)
                }
            }
        }

        // 4. Developer toolchains & system paths
        let systemPaths = [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
            "/Library/Developer/CommandLineTools/usr/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        for p in systemPaths where !paths.contains(p) {
            paths.append(p)
        }

        return paths.filter { !$0.isEmpty }
    }

    /// Resolves an executable on the filesystem by command name or absolute path.
    public static func which(_ cmd: String) -> String? {
        let fm = FileManager.default
        if cmd.hasPrefix("/") {
            return fm.isExecutableFile(atPath: cmd) ? cmd : nil
        }

        for dir in searchPaths {
            let candidate = "\(dir)/\(cmd)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    /// Constructs an environment dictionary enriched with toolchain directories in `PATH`.
    public static func makeProcessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let joinedPaths = searchPaths.joined(separator: ":")
        env["PATH"] = joinedPaths
        return env
    }
}
