import Foundation
import AppKit
import CoreText

/// Layout measurements and CoreText line cache for instant rendering
public final class LineLayoutCache: @unchecked Sendable {
    public static let shared = LineLayoutCache()

    private var lineCache: [String: CTLine] = [:]
    private var cacheKeys: [String] = []
    private let maxEntries = 500
    private let lock = NSLock()

    public init() {}

    public func getOrCreateCTLine(attributedString: NSAttributedString) -> CTLine {
        let key = attributedString.string
        lock.lock()
        defer { lock.unlock() }

        if let line = lineCache[key] {
            return line
        }

        let line = CTLineCreateWithAttributedString(attributedString)
        if cacheKeys.count >= maxEntries {
            let evicted = cacheKeys.removeFirst()
            lineCache.removeValue(forKey: evicted)
        }
        cacheKeys.append(key)
        lineCache[key] = line
        return line
    }

    public func clear() {
        lock.lock()
        lineCache.removeAll(keepingCapacity: false)
        cacheKeys.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// Converts a horizontal pixel offset X into a character index
    public func characterIndex(in line: CTLine, at xOffset: CGFloat) -> Int {
        CTLineGetStringIndexForPosition(line, CGPoint(x: xOffset, y: 0))
    }

    /// Converts a character index into a horizontal pixel offset X
    public func xOffset(in line: CTLine, for characterIndex: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(line, characterIndex, nil)
    }
}
