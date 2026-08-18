import Foundation

/// TestPlayground: файл для ручного тестирования AnyDiff
/// Здесь есть несколько секций кода, чтобы удобно проверять:
/// 1. Ввод текста и сохранение на лету (debounced auto-save)
/// 2. Нажатие Enter и живой пересчёт подсветки диффа
/// 3. Раскрытие скрытых областей (Expand) между методами
/// 4. Синтаксическую подсветку и авто-дополнение

public struct UserProfile: Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var email: String
    public var role: UserRole
    public var isVerified: Bool
    public var createdAt: Date

    public enum UserRole: String, Codable {
        case admin
        case developer
        case designer
        case guest
    }

    public init(
        id: UUID = UUID(),
        name: String,
        email: String,
        role: UserRole = .developer,
        isVerified: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.role = role
        self.isVerified = isVerified
        self.createdAt = createdAt
    }
}

// MARK: - UserManager Service

public final class UserManager {
    public static let shared = UserManager()

    private var users: [UUID: UserProfile] = [:]
    private let lock = NSLock()

    private init() {
        populateInitialMockUsers()
    }

    private func populateInitialMockUsers() {
        let sample1 = UserProfile(name: "Alice Johnson", email: "alice@example.com", role: .admin, isVerified: true)
        let sample2 = UserProfile(name: "Bob Smith", email: "bob@example.com", role: .developer, isVerified: false)
        let sample3 = UserProfile(name: "Charlie Brown", email: "charlie@example.com", role: .designer, isVerified: true)

        users[sample1.id] = sample1
        users[sample2.id] = sample2
        users[sample3.id] = sample3
    }

    public func fetchUser(by id: UUID) -> UserProfile? {
        lock.lock()
        defer { lock.unlock() }
        return users[id]
    }

    public func saveUser(_ user: UserProfile) {
        lock.lock()
        defer { lock.unlock() }
        users[user.id] = user
    }

    public func allUsers() -> [UserProfile] {
        lock.lock()
        defer { lock.unlock() }
        return Array(users.values).sorted { $0.name < $1.name }
    }

    public func deleteUser(by id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return users.removeValue(forKey: id) != nil
    }

    public func searchUsers(query: String) -> [UserProfile] {
        lock.lock()
        defer { lock.unlock() }
        guard !query.isEmpty else { return allUsers() }
        let lower = query.lowercased()
        return users.values.filter {
            $0.name.lowercased().contains(lower) || $0.email.lowercased().contains(lower)
        }
    }
}

// MARK: - Formatting & Utility Functions

public struct OutputFormatter {
    public static func format(user: UserProfile) -> String {
        """
        ==============================
        User ID:   \(user.id)
        Name:      \(user.name)
        Email:     \(user.email)
        Role:      \(user.role.rawValue.capitalized)
        Verified:  \(user.isVerified ? "YES" : "NO")
        Created:   \(user.createdAt)
        ==============================
        """
    }

    public static func printSummary() {
        let list = UserManager.shared.allUsers()
        print("Total registered users: \(list.count)")
        for user in list {
            print(format(user: user))
        }
    }
}
