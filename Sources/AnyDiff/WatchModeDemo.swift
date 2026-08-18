//
//  WatchModeDemo.swift
//  AnyDiff Live Watch Mode Test
//

import Foundation

public struct WatchModeDemo {
    public let message: String
    public let timestamp: Date
    public let updateCount: Int
    public let author: String
    public let latencyMs: Double
    public let tags: [String]

    public init(
        message: String = "✨ Cursor & Viewport position preserved across live reloads!",
        updateCount: Int = 3,
        author: String = "Max & Antigravity",
        latencyMs: Double = 3.8,
        tags: [String] = ["FSEvents", "CoreServices", "ZeroCopy", "MultiBuffer", "CursorPreserved"]
    ) {
        self.message = message
        self.timestamp = Date()
        self.updateCount = updateCount
        self.author = author
        self.latencyMs = latencyMs
        self.tags = tags
    }

    public func printStatus() {
        print("🔥 [\(timestamp)] (Rev #\(updateCount) by \(author)): \(message)")
        print("⏱️ Latency: \(latencyMs) ms | Tags: \(tags.joined(separator: ", "))")
    }

    public func celebrate() {
        print("🎉 FSEvents live reload is blazing fast!")
        print("✨ MultiBuffer synced automatically without touching a single button!")
    }

    public func simulateWork() async {
        print("⚙️ Simulating background processing...")
        try? await Task.sleep(nanoseconds: 100_000_000)
        print("✅ Done!")
    }
}
