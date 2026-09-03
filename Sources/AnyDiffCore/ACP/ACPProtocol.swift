import Foundation

// MARK: - JSON-RPC 2.0 Core Models

public struct JSONRPCRequest<T: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int
    public let method: String
    public let params: T?

    public init(id: Int, method: String, params: T? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification<T: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: T?

    public init(method: String, params: T? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse<T: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let result: T?
    public let error: JSONRPCError?

    public init(id: Int?, result: T?, error: JSONRPCError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

struct JSONRPCAnyIDRequest<T: Codable & Sendable>: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID
    let method: String
    let params: T?
}

struct JSONRPCAnyIDResponse<T: Codable & Sendable>: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCID
    let result: T?
    let error: JSONRPCError?

    init(id: JSONRPCID, result: T?, error: JSONRPCError? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct JSONRPCError: Codable, Sendable, Error, LocalizedError, CustomNSError {
    public let code: Int
    public let message: String
    public let data: String?

    public init(code: Int, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? {
        if let data = data, !data.isEmpty {
            return "\(message): \(data)"
        }
        return message
    }

    public static var errorDomain: String { "JSONRPCError" }
    public var errorCode: Int { code }
}

/// JSON-RPC request identifiers may be numbers or strings. Client-originated
/// requests in this package still use integer ids, while agent-originated
/// requests must preserve either form when we send the matching response.
public enum JSONRPCID: Codable, Sendable, Hashable {
    case integer(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .integer(int)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON-RPC id must be a string or integer")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

// MARK: - Generic Inbound Message Container for Dispatching

public struct RawJSONRPCMessage: Codable, Sendable {
    public let jsonrpc: String?
    public let id: JSONRPCID?
    public let method: String?
    public let error: JSONRPCError?
}

// MARK: - ACP Protocol Models

public struct ACPInitializeParams: Codable, Sendable {
    public let protocolVersion: Int
    public let capabilities: ACPClientCapabilities
    public let clientInfo: ACPClientInfo

    public init(protocolVersion: Int = 1, capabilities: ACPClientCapabilities = .default, clientInfo: ACPClientInfo = .default) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

public struct ACPClientCapabilities: Codable, Sendable {
    public struct BooleanConfigOptionCapabilities: Codable, Sendable {
        public init() {}
    }

    public struct SessionCapabilities: Codable, Sendable {
        public let configOptions: BooleanConfigOptionCapabilities?

        public init(configOptions: BooleanConfigOptionCapabilities? = BooleanConfigOptionCapabilities()) {
            self.configOptions = configOptions
        }
    }

    public struct FileSystemCapabilities: Codable, Sendable {
        public let readTextFile: Bool
        public let writeTextFile: Bool

        public init(readTextFile: Bool = true, writeTextFile: Bool = true) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
        }
    }

    public let fs: FileSystemCapabilities?
    public let terminal: Bool?
    public let session: SessionCapabilities?

    public init(
        fs: FileSystemCapabilities? = FileSystemCapabilities(),
        terminal: Bool? = true,
        session: SessionCapabilities? = SessionCapabilities()
    ) {
        self.fs = fs
        self.terminal = terminal
        self.session = session
    }

    public static let `default` = ACPClientCapabilities()
}

public struct ACPClientInfo: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String = "AnyDiff", version: String = "1.0.0") {
        self.name = name
        self.version = version
    }

    public static let `default` = ACPClientInfo()
}

public struct ACPInitializeResult: Codable, Sendable {
    public let protocolVersion: Int?
    public let agentInfo: ACPAgentInfo?
}

public struct ACPAgentInfo: Codable, Sendable {
    public let name: String?
    public let title: String?
    public let version: String?

    public init(name: String? = nil, title: String? = nil, version: String? = nil) {
        self.name = name
        self.title = title
        self.version = version
    }

    public var displayName: String {
        title ?? name ?? "Codex ACP"
    }
}

// MARK: - Sessions

public struct ACPSessionNewParams: Codable, Sendable {
    public let cwd: String
    public let mcpServers: [String]

    public init(cwd: String, mcpServers: [String] = []) {
        self.cwd = cwd
        self.mcpServers = mcpServers
    }
}

public struct ACPSessionListParams: Codable, Sendable {
    public let cwd: String
    public let cursor: String?

    public init(cwd: String, cursor: String? = nil) {
        self.cwd = cwd
        self.cursor = cursor
    }
}

public struct ACPSavedSessionItem: Codable, Sendable, Identifiable, Equatable {
    public var id: String { sessionId }
    public let sessionId: String
    public let cwd: String?
    public let title: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case sessionId
        case session_id
        case id
        case cwd
        case title
        case name
        case updatedAt
        case updated_at
        case createdAt
        case created_at
    }

    public init(sessionId: String, cwd: String? = nil, title: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = (try? container.decode(String.self, forKey: .sessionId))
            ?? (try? container.decode(String.self, forKey: .session_id))
            ?? (try? container.decode(String.self, forKey: .id))
            ?? UUID().uuidString
        self.cwd = try? container.decode(String.self, forKey: .cwd)
        self.title = (try? container.decode(String.self, forKey: .title))
            ?? (try? container.decode(String.self, forKey: .name))
        self.updatedAt = (try? container.decode(String.self, forKey: .updatedAt))
            ?? (try? container.decode(String.self, forKey: .updated_at))
            ?? (try? container.decode(String.self, forKey: .createdAt))
            ?? (try? container.decode(String.self, forKey: .created_at))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    public var shortId: String {
        if sessionId.count > 8 {
            return String(sessionId.prefix(8))
        }
        return sessionId
    }

    public var displayTitle: String {
        if let t = title, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t
        }
        return "Session \(shortId)"
    }

    public var parsedDate: Date? {
        guard let updatedAt, !updatedAt.isEmpty else { return nil }
        if let d = ACPSavedSessionFormatters.isoWithFractional.date(from: updatedAt) {
            return d
        }
        return ACPSavedSessionFormatters.isoStandard.date(from: updatedAt)
    }

    public var relativeTime: String {
        guard let date = parsedDate else { return "" }
        return ACPSavedSessionFormatters.relative.localizedString(for: date, relativeTo: Date())
    }

    public var formattedDate: String {
        guard let date = parsedDate else { return updatedAt ?? "" }
        let fullDate = ACPSavedSessionFormatters.display.string(from: date)
        let rel = ACPSavedSessionFormatters.relative.localizedString(for: date, relativeTo: Date())
        if !rel.isEmpty {
            return "\(rel) · \(fullDate)"
        }
        return fullDate
    }
}

private enum ACPSavedSessionFormatters {
    static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .full
        f.dateTimeStyle = .numeric
        return f
    }()

    static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

public struct ACPSessionListResult: Codable, Sendable {
    public let sessions: [ACPSavedSessionItem]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case sessions
        case items
        case nextCursor
    }

    public init(sessions: [ACPSavedSessionItem] = [], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessions = (try? container.decode([ACPSavedSessionItem].self, forKey: .sessions))
            ?? (try? container.decode([ACPSavedSessionItem].self, forKey: .items))
            ?? []
        self.nextCursor = try? container.decode(String.self, forKey: .nextCursor)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
    }
}

public struct ACPSessionLoadParams: Codable, Sendable {
    public let sessionId: String
    public let cwd: String
    public let mcpServers: [String]

    enum CodingKeys: String, CodingKey {
        case sessionId
        case session_id
        case cwd
        case mcpServers
        case mcp_servers
    }

    public init(sessionId: String, cwd: String, mcpServers: [String] = []) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = (try? container.decode(String.self, forKey: .sessionId))
            ?? (try? container.decode(String.self, forKey: .session_id))
            ?? ""
        self.cwd = (try? container.decode(String.self, forKey: .cwd)) ?? ""
        self.mcpServers = (try? container.decode([String].self, forKey: .mcpServers))
            ?? (try? container.decode([String].self, forKey: .mcp_servers))
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(mcpServers, forKey: .mcpServers)
    }
}

public struct ACPSessionLoadResult: Codable, Sendable {
    public let configOptions: [ACPConfigOption]?

    enum CodingKeys: String, CodingKey {
        case configOptions
        case config_options
        case options
        case models
        case modes
    }

    public init(configOptions: [ACPConfigOption]? = nil) {
        self.configOptions = configOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var opts: [ACPConfigOption] = []
        for k in [CodingKeys.configOptions, .config_options, .options] {
            if let list = try? container.decode([ACPConfigOption].self, forKey: k) {
                opts.append(contentsOf: list)
                break
            }
        }

        if let models = try? container.decode(ACPModelsResult.self, forKey: .models),
           let avail = models.availableModels, !avail.isEmpty {
            if !opts.contains(where: { $0.id == ACPConfigOptionID.model }) {
                opts.append(ACPConfigOption(
                    id: ACPConfigOptionID.model,
                    name: "Model",
                    category: "model",
                    type: "select",
                    currentValue: models.currentModelId,
                    options: avail
                ))
            }
        }

        if let modes = try? container.decode(ACPModesResult.self, forKey: .modes),
           let avail = modes.availableModes, !avail.isEmpty {
            if !opts.contains(where: { $0.id == ACPConfigOptionID.mode }) {
                opts.append(ACPConfigOption(
                    id: ACPConfigOptionID.mode,
                    name: "Session Mode",
                    category: "mode",
                    type: "select",
                    currentValue: modes.currentModeId,
                    options: avail
                ))
            }
        }

        self.configOptions = opts.isEmpty ? nil : opts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
    }
}

public struct ACPModelsResult: Codable, Sendable {
    public let currentModelId: String?
    public let availableModels: [ACPConfigOption.OptionValue]?

    enum CodingKeys: String, CodingKey {
        case currentModelId
        case current_model_id
        case currentModel
        case current_model
        case availableModels
        case available_models
        case models
    }

    public init(currentModelId: String? = nil, availableModels: [ACPConfigOption.OptionValue]? = nil) {
        self.currentModelId = currentModelId
        self.availableModels = availableModels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentModelId = (try? container.decode(String.self, forKey: .currentModelId))
            ?? (try? container.decode(String.self, forKey: .current_model_id))
            ?? (try? container.decode(String.self, forKey: .currentModel))
            ?? (try? container.decode(String.self, forKey: .current_model))

        var models: [ACPConfigOption.OptionValue]? = nil
        for k in [CodingKeys.availableModels, .available_models, .models] {
            if let m = try? container.decode([ACPConfigOption.OptionValue].self, forKey: k) {
                models = m
                break
            }
        }
        self.availableModels = models
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(currentModelId, forKey: .currentModelId)
        try container.encodeIfPresent(availableModels, forKey: .availableModels)
    }
}

public struct ACPModesResult: Codable, Sendable {
    public let currentModeId: String?
    public let availableModes: [ACPConfigOption.OptionValue]?

    enum CodingKeys: String, CodingKey {
        case currentModeId
        case current_mode_id
        case currentMode
        case current_mode
        case availableModes
        case available_modes
        case modes
    }

    public init(currentModeId: String? = nil, availableModes: [ACPConfigOption.OptionValue]? = nil) {
        self.currentModeId = currentModeId
        self.availableModes = availableModes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currentModeId = (try? container.decode(String.self, forKey: .currentModeId))
            ?? (try? container.decode(String.self, forKey: .current_mode_id))
            ?? (try? container.decode(String.self, forKey: .currentMode))
            ?? (try? container.decode(String.self, forKey: .current_mode))

        var modes: [ACPConfigOption.OptionValue]? = nil
        for k in [CodingKeys.availableModes, .available_modes, .modes] {
            if let m = try? container.decode([ACPConfigOption.OptionValue].self, forKey: k) {
                modes = m
                break
            }
        }
        self.availableModes = modes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(currentModeId, forKey: .currentModeId)
        try container.encodeIfPresent(availableModes, forKey: .availableModes)
    }
}

public struct ACPSessionNewResult: Codable, Sendable {
    public let sessionId: String
    public let configOptions: [ACPConfigOption]?

    public init(sessionId: String, configOptions: [ACPConfigOption]? = nil) {
        self.sessionId = sessionId
        self.configOptions = configOptions
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case session_id
        case id
        case configOptions
        case config_options
        case options
        case configuration
        case models
        case modes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = (try? container.decode(String.self, forKey: .sessionId))
            ?? (try? container.decode(String.self, forKey: .session_id))
            ?? (try? container.decode(String.self, forKey: .id))
            ?? ""

        var opts: [ACPConfigOption] = []
        for k in [CodingKeys.configOptions, .config_options, .options, .configuration] {
            if let list = try? container.decode([ACPConfigOption].self, forKey: k) {
                opts.append(contentsOf: list)
                break
            }
        }

        // If server sent "models" object (e.g. OpenCode with models dictionary):
        if let models = try? container.decode(ACPModelsResult.self, forKey: .models),
           let avail = models.availableModels, !avail.isEmpty {
            if !opts.contains(where: { $0.id == ACPConfigOptionID.model }) {
                opts.append(ACPConfigOption(
                    id: ACPConfigOptionID.model,
                    name: "Model",
                    category: "model",
                    type: "select",
                    currentValue: models.currentModelId,
                    options: avail
                ))
            }
        }

        // If server sent "modes" object:
        if let modes = try? container.decode(ACPModesResult.self, forKey: .modes),
           let avail = modes.availableModes, !avail.isEmpty {
            if !opts.contains(where: { $0.id == ACPConfigOptionID.mode }) {
                opts.append(ACPConfigOption(
                    id: ACPConfigOptionID.mode,
                    name: "Session Mode",
                    category: "mode",
                    type: "select",
                    currentValue: modes.currentModeId,
                    options: avail
                ))
            }
        }

        self.configOptions = opts.isEmpty ? nil : opts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
    }
}

// MARK: - Config Options

public enum ACPConfigOptionID {
    public static let model = "model"
    public static let reasoningEffort = "reasoning_effort"
    public static let fastMode = "fast-mode"
    public static let mode = "mode"
}

public struct ACPConfigOption: Codable, Sendable, Identifiable {
    public struct OptionValue: Codable, Sendable {
        public let value: String
        public let name: String
        public let description: String?

        public init(value: String, name: String, description: String? = nil) {
            self.value = value
            self.name = name
            self.description = description
        }

        enum CodingKeys: String, CodingKey {
            case value
            case modelId
            case model_id
            case id
            case val
            case key
            case name
            case label
            case title
            case displayName
            case display_name
            case text
            case description
            case desc
        }

        public init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                var extractedVal: String?
                for key in [CodingKeys.value, .modelId, .model_id, .id, .val, .key] {
                    if let v = try? container.decode(String.self, forKey: key), !v.isEmpty {
                        extractedVal = v
                        break
                    }
                }
                let finalVal = extractedVal ?? ""

                var extractedName: String?
                for key in [CodingKeys.name, .label, .title, .displayName, .display_name, .text] {
                    if let n = try? container.decode(String.self, forKey: key), !n.isEmpty {
                        extractedName = n
                        break
                    }
                }

                var extractedDesc: String?
                for key in [CodingKeys.description, .desc] {
                    if let d = try? container.decode(String.self, forKey: key), !d.isEmpty {
                        extractedDesc = d
                        break
                    }
                }

                self.value = finalVal
                self.name = (extractedName?.isEmpty == false) ? extractedName! : finalVal
                self.description = extractedDesc
                return
            }

            // Support single scalar string in an array: ["opt1", "opt2"]
            if let singleContainer = try? decoder.singleValueContainer(),
               let singleStr = try? singleContainer.decode(String.self) {
                self.value = singleStr
                self.name = singleStr
                self.description = nil
                return
            }

            self.value = ""
            self.name = ""
            self.description = nil
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }

    public let id: String
    public let name: String
    public let description: String?
    public let category: String?
    public let type: String?
    public var currentValue: String?
    public let options: [OptionValue]?

    public init(id: String, name: String, description: String? = nil, category: String? = nil, type: String? = nil, currentValue: String? = nil, options: [OptionValue]? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.type = type
        self.currentValue = currentValue
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case desc
        case category
        case type
        case currentValue
        case current_value
        case value
        case selected
        case `default`
        case options
        case choices
        case values
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decode(String.self, forKey: .id)) ?? "option"
        self.name = (try? container.decode(String.self, forKey: .name)) ?? self.id

        var desc: String? = nil
        for k in [CodingKeys.description, .desc] {
            if let d = try? container.decode(String.self, forKey: k) {
                desc = d
                break
            }
        }
        self.description = desc
        self.category = try? container.decode(String.self, forKey: .category)
        self.type = try? container.decode(String.self, forKey: .type)

        var curVal: String? = nil
        for k in [CodingKeys.currentValue, .current_value, .value, .selected, .default] {
            if let s = Self.decodeScalarString(from: container, forKey: k) {
                curVal = s
                break
            }
        }
        self.currentValue = curVal

        var opts: [OptionValue]? = nil
        if let o = try? container.decode([OptionValue].self, forKey: .options) {
            opts = o
        } else if let c = try? container.decode([OptionValue].self, forKey: .choices) {
            opts = c
        } else if let v = try? container.decode([OptionValue].self, forKey: .values) {
            opts = v
        }
        self.options = opts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(currentValue, forKey: .currentValue)
        try container.encodeIfPresent(options, forKey: .options)
    }

    private static func decodeScalarString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Bool.self, forKey: key) { return value ? "true" : "false" }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(value) }
        return nil
    }
}

public struct ACPSetConfigOptionParams: Codable, Sendable {
    public let sessionId: String
    public let configId: String
    public let value: String

    public init(sessionId: String, configId: String, value: String) {
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
    }
}

public struct ACPSetConfigOptionResult: Codable, Sendable {
    public let configOptions: [ACPConfigOption]?

    enum CodingKeys: String, CodingKey {
        case configOptions
        case config_options
        case options
        case models
        case modes
    }

    public init(configOptions: [ACPConfigOption]? = nil) {
        self.configOptions = configOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var opts: [ACPConfigOption] = []
        for k in [CodingKeys.configOptions, .config_options, .options] {
            if let list = try? container.decode([ACPConfigOption].self, forKey: k) {
                opts.append(contentsOf: list)
                break
            }
        }

        if let models = try? container.decode(ACPModelsResult.self, forKey: .models),
           let avail = models.availableModels, !avail.isEmpty {
            if !opts.contains(where: { $0.id == ACPConfigOptionID.model }) {
                opts.append(ACPConfigOption(
                    id: ACPConfigOptionID.model,
                    name: "Model",
                    category: "model",
                    type: "select",
                    currentValue: models.currentModelId,
                    options: avail
                ))
            }
        }

        if let modes = try? container.decode(ACPModesResult.self, forKey: .modes),
           let avail = modes.availableModes, !avail.isEmpty {
            if !opts.contains(where: { $0.id == ACPConfigOptionID.mode }) {
                opts.append(ACPConfigOption(
                    id: ACPConfigOptionID.mode,
                    name: "Session Mode",
                    category: "mode",
                    type: "select",
                    currentValue: modes.currentModeId,
                    options: avail
                ))
            }
        }

        self.configOptions = opts.isEmpty ? nil : opts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(configOptions, forKey: .configOptions)
    }
}

public struct ACPSessionPromptParams: Codable, Sendable {
    public struct PromptItem: Codable, Sendable, Equatable {
        public let type: String
        public let text: String?
        public let data: String?
        public let mimeType: String?
        public let uri: String?

        public init(type: String = "text", text: String? = nil, data: String? = nil, mimeType: String? = nil, uri: String? = nil) {
            self.type = type
            self.text = text
            self.data = data
            self.mimeType = mimeType
            self.uri = uri
        }

        public init(type: String = "text", text: String) {
            self.type = type
            self.text = text
            self.data = nil
            self.mimeType = nil
            self.uri = nil
        }

        public static func text(_ text: String) -> PromptItem {
            PromptItem(type: "text", text: text)
        }

        public static func image(data: String, mimeType: String, uri: String? = nil) -> PromptItem {
            PromptItem(type: "image", text: nil, data: data, mimeType: mimeType, uri: uri)
        }

        public static func image(attachment: AgentImageAttachment) -> PromptItem {
            PromptItem(type: "image", text: nil, data: attachment.base64String, mimeType: attachment.mimeType, uri: nil)
        }
    }

    public let sessionId: String
    public let prompt: [PromptItem]

    public init(sessionId: String, text: String) {
        self.sessionId = sessionId
        self.prompt = [PromptItem(type: "text", text: text)]
    }

    public init(sessionId: String, prompt: [PromptItem]) {
        self.sessionId = sessionId
        self.prompt = prompt
    }

    public init(sessionId: String, text: String, images: [AgentImageAttachment] = []) {
        self.sessionId = sessionId
        var items: [PromptItem] = []
        if !text.isEmpty {
            items.append(.text(text))
        }
        for img in images {
            items.append(.image(attachment: img))
        }
        self.prompt = items.isEmpty ? [PromptItem.text(text)] : items
    }
}

public struct ACPSessionCancelParams: Codable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// MARK: - Permission Requests (Agent -> Client)

public struct ACPPermissionOption: Codable, Sendable, Equatable, Identifiable {
    public let optionId: String
    public let name: String
    public let kind: String?

    public var id: String { optionId }

    public init(optionId: String, name: String, kind: String? = nil) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case optionId
        case option_id
        case name
        case kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = (try? container.decode(String.self, forKey: .optionId))
            ?? (try? container.decode(String.self, forKey: .option_id)) else {
            throw DecodingError.keyNotFound(
                CodingKeys.optionId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing permission option id")
            )
        }
        self.optionId = id
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try? container.decode(String.self, forKey: .kind)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(optionId, forKey: .optionId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(kind, forKey: .kind)
    }
}

public struct ACPPermissionToolCall: Codable, Sendable {
    public let toolCallId: String
    public let title: String?
    public let kind: String?
    public let status: String?
    public let rawInput: [String: AnyCodableSendable]?

    public init(
        toolCallId: String,
        title: String? = nil,
        kind: String? = nil,
        status: String? = nil,
        rawInput: [String: AnyCodableSendable]? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.rawInput = rawInput
    }

    enum CodingKeys: String, CodingKey {
        case toolCallId
        case tool_call_id
        case title
        case kind
        case status
        case rawInput
        case raw_input
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = (try? container.decode(String.self, forKey: .toolCallId))
            ?? (try? container.decode(String.self, forKey: .tool_call_id)) else {
            throw DecodingError.keyNotFound(
                CodingKeys.toolCallId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing tool call id")
            )
        }
        self.toolCallId = id
        self.title = try? container.decode(String.self, forKey: .title)
        self.kind = try? container.decode(String.self, forKey: .kind)
        self.status = try? container.decode(String.self, forKey: .status)
        self.rawInput = (try? container.decode([String: AnyCodableSendable].self, forKey: .rawInput))
            ?? (try? container.decode([String: AnyCodableSendable].self, forKey: .raw_input))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(rawInput, forKey: .rawInput)
    }
}

public struct ACPRequestPermissionParams: Codable, Sendable {
    public let sessionId: String
    public let toolCall: ACPPermissionToolCall
    public let options: [ACPPermissionOption]

    public init(sessionId: String, toolCall: ACPPermissionToolCall, options: [ACPPermissionOption]) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }
}

public struct ACPRequestPermissionResult: Codable, Sendable, Equatable {
    public struct Outcome: Codable, Sendable, Equatable {
        public let outcome: String
        public let optionId: String?

        public init(outcome: String, optionId: String? = nil) {
            self.outcome = outcome
            self.optionId = optionId
        }
    }

    public let outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }

    public static func selected(optionId: String) -> Self {
        Self(outcome: Outcome(outcome: "selected", optionId: optionId))
    }

    public static var cancelled: Self {
        Self(outcome: Outcome(outcome: "cancelled"))
    }
}

// MARK: - Session Updates (Streaming Notifications)

public struct ACPSessionUpdateNotificationParams: Codable, Sendable {
    public let sessionId: String
    public let update: ACPSessionUpdateContent
}

public struct ACPSessionUpdateContent: Codable, Sendable {
    public let type: String?
    public let kind: String?
    public let title: String?
    public let contentText: String?
    public let delta: String?
    public let toolCallId: String?
    public let toolName: String?
    public let toolInput: [String: AnyCodableSendable]?
    public let toolResult: String?
    public let isError: Bool?
    public let used: Int?
    public let status: String?
    public let size: Int?

    public var effectiveType: String {
        type ?? "message_chunk"
    }

    public var effectiveChunk: String {
        delta ?? contentText ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sessionUpdate
        case kind
        case event
        case content
        case delta
        case messageId
        case toolCallId
        case tool_call_id
        case callId
        case call_id
        case id
        case toolName
        case tool_name
        case name
        case tool
        case title
        case toolInput
        case tool_input
        case input
        case rawInput
        case raw_input
        case arguments
        case parameters
        case params
        case toolResult
        case tool_result
        case result
        case output
        case rawOutput
        case raw_output
        case formatted_output
        case formattedOutput
        case stdout
        case stderr
        case response
        case data
        case isError
        case status
        case state
        case used
        case size
    }

    public init(
        type: String? = nil,
        kind: String? = nil,
        title: String? = nil,
        content: String? = nil,
        contentText: String? = nil,
        delta: String? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        toolInput: [String: AnyCodableSendable]? = nil,
        toolResult: String? = nil,
        isError: Bool? = nil,
        status: String? = nil,
        used: Int? = nil,
        size: Int? = nil
    ) {
        self.type = type
        self.kind = kind
        self.title = title
        self.contentText = contentText ?? content
        self.delta = delta
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolResult = toolResult
        self.isError = isError
        self.status = status
        self.used = used
        self.size = size
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let sUpdate = try? container.decode(String.self, forKey: .sessionUpdate)
        let t = try? container.decode(String.self, forKey: .type)
        let k = try? container.decode(String.self, forKey: .kind)
        let ev = try? container.decode(String.self, forKey: .event)
        self.type = sUpdate ?? t ?? k ?? ev
        self.kind = k

        let titleVal = try? container.decode(String.self, forKey: .title)
        self.title = titleVal

        self.delta = try? container.decode(String.self, forKey: .delta)

        // 1. Tool Input decoding
        var extractedInput: [String: AnyCodableSendable] = [:]
        let inputKeys: [CodingKeys] = [.rawInput, .raw_input, .toolInput, .tool_input, .input, .arguments, .parameters, .params]
        for key in inputKeys {
            if let raw = try? container.decode([String: AnyCodableSendable].self, forKey: key) {
                extractedInput.merge(raw) { (_, new) in new }
            }
        }

        // 2. Decode Content & extract embedded diffs / commands
        if let stringContent = try? container.decode(String.self, forKey: .content) {
            self.contentText = stringContent
        } else if let dictContent = try? container.decode([String: AnyCodableSendable].self, forKey: .content) {
            self.contentText = dictContent["text"]?.description ?? dictContent["output"]?.description
            extractedInput.merge(dictContent) { (current, _) in current }
        } else if let arrContent = try? container.decode([AnyCodableSendable].self, forKey: .content) {
            var textParts: [String] = []
            for item in arrContent {
                if let d = item.value as? [String: Any] {
                    if let txt = (d["text"] as? String) ?? (d["output"] as? String) ?? (d["content"] as? String) {
                        textParts.append(txt)
                    }
                    if let path = d["path"] as? String {
                        extractedInput["path"] = AnyCodableSendable(path)
                    }
                    if let oldText = (d["oldText"] as? String) ?? (d["old_text"] as? String) ?? (d["oldContent"] as? String) {
                        extractedInput["old_content"] = AnyCodableSendable(oldText)
                    }
                    if let newText = (d["newText"] as? String) ?? (d["new_text"] as? String) ?? (d["newContent"] as? String) {
                        extractedInput["new_content"] = AnyCodableSendable(newText)
                    }
                    if let cmd = d["command"] as? String {
                        extractedInput["command"] = AnyCodableSendable(cmd)
                    }
                } else {
                    textParts.append(String(describing: item.value))
                }
            }
            self.contentText = textParts.isEmpty ? nil : textParts.joined(separator: "\n")
        } else {
            self.contentText = nil
        }

        self.toolInput = extractedInput.isEmpty ? nil : extractedInput

        let tid1 = try? container.decode(String.self, forKey: .toolCallId)
        let tid2 = try? container.decode(String.self, forKey: .tool_call_id)
        let tid3 = try? container.decode(String.self, forKey: .callId)
        let tid4 = try? container.decode(String.self, forKey: .call_id)
        let tid5 = try? container.decode(String.self, forKey: .id)
        self.toolCallId = tid1 ?? tid2 ?? tid3 ?? tid4 ?? tid5

        let tn1 = try? container.decode(String.self, forKey: .toolName)
        let tn2 = try? container.decode(String.self, forKey: .tool_name)
        let tn3 = try? container.decode(String.self, forKey: .name)
        let tn4 = try? container.decode(String.self, forKey: .tool)
        self.toolName = tn1 ?? tn2 ?? tn3 ?? tn4 ?? k ?? titleVal

        self.toolResult = Self.extractStringResult(
            from: container,
            keys: [.rawOutput, .raw_output, .toolResult, .tool_result, .stdout, .stderr, .result, .output, .response, .content, .data]
        )

        self.isError = try? container.decode(Bool.self, forKey: .isError)
        let st1 = try? container.decode(String.self, forKey: .status)
        let st2 = try? container.decode(String.self, forKey: .state)
        self.status = st1 ?? st2

        self.used = try? container.decode(Int.self, forKey: .used)
        self.size = try? container.decode(Int.self, forKey: .size)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(contentText, forKey: .content)
        try container.encodeIfPresent(delta, forKey: .delta)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(toolInput, forKey: .toolInput)
        try container.encodeIfPresent(toolResult, forKey: .toolResult)
        try container.encodeIfPresent(isError, forKey: .isError)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(used, forKey: .used)
        try container.encodeIfPresent(size, forKey: .size)
    }

    private static func extractStringResult(from container: KeyedDecodingContainer<CodingKeys>, keys: [CodingKeys]) -> String? {
        for key in keys {
            if let str = try? container.decode(String.self, forKey: key) {
                return str
            }
            if let dict = try? container.decode([String: AnyCodableSendable].self, forKey: key) {
                if let formatted = dict["formatted_output"]?.description, !formatted.isEmpty {
                    return formatted
                }
                if let stdout = dict["stdout"]?.description, !stdout.isEmpty {
                    return stdout
                }
                if let output = dict["output"]?.description, !output.isEmpty {
                    return output
                }
                if let text = dict["text"]?.description, !text.isEmpty {
                    return text
                }
                if let content = dict["content"]?.description, !content.isEmpty {
                    return content
                }
                if let val = dict["value"]?.description, !val.isEmpty {
                    return val
                }
                let joined = dict.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                if !joined.isEmpty { return joined }
            }
            if let arr = try? container.decode([AnyCodableSendable].self, forKey: key) {
                let texts = arr.compactMap { item -> String? in
                    if let d = item.value as? [String: Any] {
                        return (d["text"] as? String) ?? (d["output"] as? String) ?? (d["content"] as? String)
                    }
                    return String(describing: item.value)
                }
                if !texts.isEmpty {
                    return texts.joined(separator: "\n")
                }
            }
        }
        return nil
    }
}

// MARK: - File System Client Requests (Agent -> Client)

public struct ACPFSReadTextFileParams: Codable, Sendable {
    public let path: String
}

public struct ACPFSReadTextFileResult: Codable, Sendable {
    public let content: String

    public init(content: String) {
        self.content = content
    }
}

public struct ACPFSWriteTextFileParams: Codable, Sendable {
    public let path: String
    public let content: String
}

public struct ACPFSWriteTextFileResult: Codable, Sendable {
    public let success: Bool

    public init(success: Bool = true) {
        self.success = success
    }
}

// MARK: - Terminal Client Requests (Agent -> Client)

public struct ACPTerminalCreateParams: Codable, Sendable {
    public let command: String?
    public let cwd: String?
}

public struct ACPTerminalCreateResult: Codable, Sendable {
    public let terminalId: String

    public init(terminalId: String) {
        self.terminalId = terminalId
    }
}

public struct ACPTerminalOutputParams: Codable, Sendable {
    public let terminalId: String
    public let output: String
}

public struct ACPTerminalWaitForExitParams: Codable, Sendable {
    public let terminalId: String
}

public struct ACPTerminalWaitForExitResult: Codable, Sendable {
    public let exitCode: Int

    public init(exitCode: Int) {
        self.exitCode = exitCode
    }
}

// MARK: - AnyCodableSendable Helper for Dynamic JSON Fields

public struct AnyCodableSendable: Codable, @unchecked Sendable, CustomStringConvertible {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public var description: String {
        String(describing: value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodableSendable].self) {
            self.value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyCodableSendable].self) {
            self.value = dictionary.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodableSendable")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodableSendable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodableSendable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}
