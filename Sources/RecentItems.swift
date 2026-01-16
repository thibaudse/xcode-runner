import Foundation

/// Manages recently used schemes and devices
actor RecentItemsManager {
    static let shared = RecentItemsManager()

    private let maxRecent = 5
    private static let userDefaultsKey = "xcode-runner.recent"
    private static let userDefaults: UserDefaults = {
        UserDefaults(suiteName: "xcode-runner") ?? .standard
    }()

    private var data: RecentData

    private init() {
        if let loaded = Self.loadFromUserDefaults() {
            data = loaded
        } else {
            data = RecentData(schemes: [:], devices: [])
        }
    }

    // MARK: - Schemes (per project)

    func getRecentSchemes(forProject projectPath: String) -> [String] {
        return data.schemes[projectPath] ?? []
    }

    func addRecentScheme(_ scheme: String, forProject projectPath: String) {
        var schemes = data.schemes[projectPath] ?? []

        // Remove if already exists (will be re-added at front)
        schemes.removeAll { $0 == scheme }

        // Add to front
        schemes.insert(scheme, at: 0)

        // Keep only maxRecent
        if schemes.count > maxRecent {
            schemes = Array(schemes.prefix(maxRecent))
        }

        data.schemes[projectPath] = schemes
        save()
    }

    // MARK: - Devices (global)

    func getRecentDevices() -> [String] {
        return data.devices
    }

    func addRecentDevice(_ deviceId: String) {
        // Remove if already exists
        data.devices.removeAll { $0 == deviceId }

        // Add to front
        data.devices.insert(deviceId, at: 0)

        // Keep only maxRecent
        if data.devices.count > maxRecent {
            data.devices = Array(data.devices.prefix(maxRecent))
        }

        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        Self.userDefaults.set(encoded, forKey: Self.userDefaultsKey)
        Self.userDefaults.synchronize()
    }

    private static func loadFromUserDefaults() -> RecentData? {
        guard let data = userDefaults.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(RecentData.self, from: data)
    }
}

// MARK: - Data Model

private struct RecentData: Codable {
    var schemes: [String: [String]]  // projectPath -> [scheme names]
    var devices: [String]            // [device IDs]
}
