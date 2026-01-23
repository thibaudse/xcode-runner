import Foundation

/// Represents a device that can run apps
struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let type: DeviceType
    let platform: Platform
    let state: DeviceState
    let runtime: String?
    let osVersion: String?

    enum DeviceType: String, CaseIterable {
        case simulator
        case physical
        case mac  // Mac is a special case - it's the local machine

        var icon: String {
            switch self {
            case .simulator: return "📱"
            case .physical: return "📲"
            case .mac: return "🖥️"
            }
        }
    }

    enum Platform: String, CaseIterable {
        case iOS
        case macOS
        case watchOS
        case tvOS
        case visionOS

        var displayName: String {
            switch self {
            case .iOS: return "iOS"
            case .macOS: return "macOS"
            case .watchOS: return "watchOS"
            case .tvOS: return "tvOS"
            case .visionOS: return "visionOS"
            }
        }

        var icon: String {
            switch self {
            case .iOS: return "📱"
            case .macOS: return "🖥️"
            case .watchOS: return "⌚"
            case .tvOS: return "📺"
            case .visionOS: return "🥽"
            }
        }

        /// The platform identifier used in xcodebuild destinations
        var simulatorPlatform: String {
            switch self {
            case .iOS: return "iOS Simulator"
            case .macOS: return "macOS"
            case .watchOS: return "watchOS Simulator"
            case .tvOS: return "tvOS Simulator"
            case .visionOS: return "visionOS Simulator"
            }
        }

        /// The platform identifier for physical devices
        var devicePlatform: String {
            switch self {
            case .iOS: return "iOS"
            case .macOS: return "macOS"
            case .watchOS: return "watchOS"
            case .tvOS: return "tvOS"
            case .visionOS: return "visionOS"
            }
        }

        /// The build products directory suffix
        var buildProductsSuffix: String {
            switch self {
            case .iOS: return "iphoneos"
            case .macOS: return "macosx"
            case .watchOS: return "watchos"
            case .tvOS: return "appletvos"
            case .visionOS: return "xros"
            }
        }

        /// The build products directory suffix for simulators
        var simulatorBuildProductsSuffix: String {
            switch self {
            case .iOS: return "iphonesimulator"
            case .macOS: return "macosx"  // macOS doesn't have a simulator
            case .watchOS: return "watchsimulator"
            case .tvOS: return "appletvsimulator"
            case .visionOS: return "xrsimulator"
            }
        }
    }

    enum DeviceState: String {
        case available
        case booted
        case shutdown
        case unavailable

        var icon: String {
            switch self {
            case .available, .booted: return "●".green
            case .shutdown: return "○".dim
            case .unavailable: return "✗".red
            }
        }

        var label: String {
            switch self {
            case .booted: return "Running".green
            case .shutdown: return "Shutdown".dim
            case .available: return "Available".green
            case .unavailable: return "Unavailable".red
            }
        }
    }

    var displayName: String {
        let icon = type == .mac ? type.icon : platform.icon
        var display = "\(icon) \(name)"
        if let version = osVersion {
            display += " (\(version))".dim
        }
        return display
    }

    var stateDisplay: String {
        state.label
    }
}

/// Manages device discovery
actor DeviceManager {
    static let shared = DeviceManager()

    private init() {}

    // MARK: - Simulators

    func discoverSimulators() async throws -> [Device] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let response = try JSONDecoder().decode(SimCtlResponse.self, from: data)

        var devices: [Device] = []

        for (runtimeId, simDevices) in response.devices {
            // Parse runtime to get OS version and platform
            guard let (osVersion, platform) = parseRuntime(runtimeId) else { continue }

            for simDevice in simDevices {
                let state: Device.DeviceState = simDevice.state == "Booted" ? .booted : .shutdown
                let device = Device(
                    id: simDevice.udid,
                    name: simDevice.name,
                    type: .simulator,
                    platform: platform,
                    state: state,
                    runtime: runtimeId,
                    osVersion: osVersion
                )
                devices.append(device)
            }
        }

        // Sort: booted first, then by platform, then by name
        return devices.sorted { lhs, rhs in
            if lhs.state == .booted && rhs.state != .booted { return true }
            if lhs.state != .booted && rhs.state == .booted { return false }
            // Group by platform
            if lhs.platform != rhs.platform {
                return lhs.platform.rawValue < rhs.platform.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    private func parseRuntime(_ runtimeId: String) -> (version: String, platform: Device.Platform)? {
        // Format: com.apple.CoreSimulator.SimRuntime.iOS-17-0
        // or: com.apple.CoreSimulator.SimRuntime.watchOS-10-0
        // or: com.apple.CoreSimulator.SimRuntime.tvOS-17-0
        // or: com.apple.CoreSimulator.SimRuntime.xrOS-2-0

        let platformPatterns: [(pattern: String, platform: Device.Platform, prefix: String)] = [
            (#"iOS-(\d+)-(\d+)"#, .iOS, "iOS"),
            (#"watchOS-(\d+)-(\d+)"#, .watchOS, "watchOS"),
            (#"tvOS-(\d+)-(\d+)"#, .tvOS, "tvOS"),
            (#"xrOS-(\d+)-(\d+)"#, .visionOS, "visionOS"),
        ]

        for (pattern, platform, prefix) in platformPatterns {
            if let match = runtimeId.range(of: pattern, options: .regularExpression) {
                let versionPart = String(runtimeId[match])
                // Extract version numbers
                let components = versionPart.components(separatedBy: "-")
                if components.count >= 2 {
                    let major = components[1]
                    let minor = components.count > 2 ? components[2] : "0"
                    let version = "\(prefix) \(major).\(minor)"
                    return (version, platform)
                }
            }
        }
        return nil
    }

    // MARK: - Physical Devices

    func discoverPhysicalDevices() async throws -> [Device] {
        // Use xctrace which returns the correct device IDs for xcodebuild
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctrace", "list", "devices"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var devices: [Device] = []
        var inDevicesSection = false

        // Parse output format:
        // == Devices ==
        // Device Name (iOS Version) (UDID)
        // My Mac (macOS Version) (UDID)
        // == Simulators ==
        // ...
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "== Devices ==" {
                inDevicesSection = true
                continue
            } else if trimmed.hasPrefix("== ") {
                inDevicesSection = false
                continue
            }

            guard inDevicesSection, !trimmed.isEmpty else { continue }

            // Try to parse device line - two possible formats:
            // 1. "Device Name (Version) (UDID)" - for iOS, watchOS, tvOS devices
            // 2. "Device Name (UDID)" - for Mac (no version in output)

            // First try format with version: "Name (Version) (UDID)"
            let patternWithVersion = #"^(.+?)\s+\(([^)]+)\)\s+\(([^)]+)\)$"#
            if let regex = try? NSRegularExpression(pattern: patternWithVersion),
               let result = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {

                let nameRange = Range(result.range(at: 1), in: trimmed)
                let versionRange = Range(result.range(at: 2), in: trimmed)
                let udidRange = Range(result.range(at: 3), in: trimmed)

                if let nameRange, let versionRange, let udidRange {
                    let name = String(trimmed[nameRange])
                    let version = String(trimmed[versionRange])
                    let udid = String(trimmed[udidRange])

                    // Determine platform and device type based on name
                    let (platform, deviceType, osVersion) = classifyDevice(name: name, version: version)

                    let device = Device(
                        id: udid,
                        name: name,
                        type: deviceType,
                        platform: platform,
                        state: .available,
                        runtime: nil,
                        osVersion: osVersion
                    )
                    devices.append(device)
                    continue
                }
            }

            // Try format without version: "Name (UDID)" - typically Mac
            let patternWithoutVersion = #"^(.+?)\s+\(([A-Fa-f0-9-]+)\)$"#
            if let regex = try? NSRegularExpression(pattern: patternWithoutVersion),
               let result = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {

                let nameRange = Range(result.range(at: 1), in: trimmed)
                let udidRange = Range(result.range(at: 2), in: trimmed)

                if let nameRange, let udidRange {
                    let name = String(trimmed[nameRange])
                    let udid = String(trimmed[udidRange])

                    // Mac devices don't have version in xctrace output
                    let (platform, deviceType, osVersion) = classifyDevice(name: name, version: nil)

                    let device = Device(
                        id: udid,
                        name: name,
                        type: deviceType,
                        platform: platform,
                        state: .available,
                        runtime: nil,
                        osVersion: osVersion
                    )
                    devices.append(device)
                }
            }
        }

        // Sort by platform then name
        return devices.sorted { lhs, rhs in
            if lhs.platform != rhs.platform {
                return lhs.platform.rawValue < rhs.platform.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    private func classifyDevice(name: String, version: String?) -> (platform: Device.Platform, deviceType: Device.DeviceType, osVersion: String?) {
        let lowercased = name.lowercased()

        // Mac devices (version may be nil as xctrace doesn't include it)
        if lowercased.contains("my mac") || lowercased.contains("macbook") ||
           lowercased.contains("imac") || lowercased.contains("mac mini") ||
           lowercased.contains("mac pro") || lowercased.contains("mac studio") {
            let osVersion = version.map { "macOS \($0)" }
            return (.macOS, .mac, osVersion)
        }

        // Apple Watch devices
        if lowercased.contains("watch") {
            let osVersion = version.map { "watchOS \($0)" }
            return (.watchOS, .physical, osVersion)
        }

        // Apple TV devices
        if lowercased.contains("apple tv") || lowercased.contains("appletv") {
            let osVersion = version.map { "tvOS \($0)" }
            return (.tvOS, .physical, osVersion)
        }

        // Vision Pro devices
        if lowercased.contains("vision") {
            let osVersion = version.map { "visionOS \($0)" }
            return (.visionOS, .physical, osVersion)
        }

        // Default to iOS (iPhone, iPad, iPod)
        let osVersion = version.map { "iOS \($0)" }
        return (.iOS, .physical, osVersion)
    }

    // MARK: - Combined Discovery

    func discoverAllDevices() async throws -> [Device] {
        async let simulators = discoverSimulators()
        async let physical = discoverPhysicalDevices()

        let allSimulators = try await simulators
        let allPhysical = try await physical

        // Physical devices first, then simulators
        return allPhysical + allSimulators
    }
}

// MARK: - JSON Models

private struct SimCtlResponse: Decodable {
    let devices: [String: [SimDevice]]
}

private struct SimDevice: Decodable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool
}

private struct DeviceCtlResponse: Decodable {
    let result: DeviceCtlResult
}

private struct DeviceCtlResult: Decodable {
    let devices: [DeviceCtlDevice]
}

private struct DeviceCtlDevice: Decodable {
    let identifier: String
    let deviceProperties: DeviceCtlProperties
    let connectionProperties: DeviceCtlConnection?
}

private struct DeviceCtlProperties: Decodable {
    let name: String
    let osVersionNumber: String?
}

private struct DeviceCtlConnection: Decodable {
    let transportType: String?
}
