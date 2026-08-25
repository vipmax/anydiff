import Foundation

public struct AgentImageAttachment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    private var inMemoryData: Data?
    public let filePath: String?
    public let mimeType: String
    public let filename: String?
    public let width: Double?
    public let height: Double?
    public let fileSize: Int

    public init(
        id: UUID = UUID(),
        data: Data? = nil,
        filePath: String? = nil,
        mimeType: String = "image/png",
        filename: String? = nil,
        width: Double? = nil,
        height: Double? = nil,
        fileSize: Int? = nil
    ) {
        self.id = id
        self.inMemoryData = data
        self.filePath = filePath
        self.mimeType = mimeType
        self.filename = filename
        self.width = width
        self.height = height
        self.fileSize = fileSize ?? (data?.count ?? 0)
    }

    public var data: Data {
        if let mem = inMemoryData {
            return mem
        }
        if let path = filePath, let diskData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return diskData
        }
        return Data()
    }

    public var base64String: String {
        data.base64EncodedString()
    }

    public var fileSizeDescription: String {
        let count = fileSize > 0 ? fileSize : data.count
        if count < 1024 {
            return "\(count) B"
        } else if count < 1024 * 1024 {
            return String(format: "%.1f KB", Double(count) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(count) / (1024.0 * 1024.0))
        }
    }

    public static func == (lhs: AgentImageAttachment, rhs: AgentImageAttachment) -> Bool {
        lhs.id == rhs.id &&
        lhs.filePath == rhs.filePath &&
        lhs.mimeType == rhs.mimeType &&
        lhs.filename == rhs.filename &&
        lhs.width == rhs.width &&
        lhs.height == rhs.height &&
        lhs.fileSize == rhs.fileSize
    }
}
