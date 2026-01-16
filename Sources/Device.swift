import Foundation

/// Represents a device that can run iOS apps
struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let type: DeviceType
    let state: DeviceState
    let runtime: String?
    let osVersion: String?

    enum DeviceType: String, CaseIterable {
        case simulator
        case physical

        var icon: String {
            switch self {
            case .simulator: return "📱"
            case .physical: return "📲"
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
        var display = "\(type.icon) \(name)"
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
            // Parse runtime to get OS version
            let osVersion = parseRuntime(runtimeId)

            // Filter to iOS devices only
            guard runtimeId.contains("iOS") || runtimeId.contains("iPhone") else { continue }

            for simDevice in simDevices {
                let state: Device.DeviceState = simDevice.state == "Booted" ? .booted : .shutdown
                let device = Device(
                    id: simDevice.udid,
                    name: simDevice.name,
                    type: .simulator,
                    state: state,
                    runtime: runtimeId,
                    osVersion: osVersion
                )
                devices.append(device)
            }
        }

        // Sort: booted first, then by name
        return devices.sorted { lhs, rhs in
            if lhs.state == .booted && rhs.state != .booted { return true }
            if lhs.state != .booted && rhs.state == .booted { return false }
            return lhs.name < rhs.name
        }
    }

    private func parseRuntime(_ runtimeId: String) -> String? {
        // Format: com.apple.CoreSimulator.SimRuntime.iOS-17-0
        let pattern = #"iOS-(\d+)-(\d+)"#
        if let match = runtimeId.range(of: pattern, options: .regularExpression) {
            let version = runtimeId[match]
                .replacingOccurrences(of: "iOS-", with: "iOS ")
                .replacingOccurrences(of: "-", with: ".")
            return version
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

            // Parse: "Device Name (iOS Version) (UDID)"
            // Example: "Thibaud's iPhone (18.2) (00008130-00063CA12250001C)"
            if let match = trimmed.range(of: #"^(.+?)\s+\(([^)]+)\)\s+\(([^)]+)\)$"#, options: .regularExpression) {
                let matchedString = String(trimmed[match])

                // Extract parts using regex groups
                let pattern = #"^(.+?)\s+\(([^)]+)\)\s+\(([^)]+)\)$"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let result = regex.firstMatch(in: matchedString, range: NSRange(matchedString.startIndex..., in: matchedString)) {

                    let nameRange = Range(result.range(at: 1), in: matchedString)
                    let versionRange = Range(result.range(at: 2), in: matchedString)
                    let udidRange = Range(result.range(at: 3), in: matchedString)

                    if let nameRange, let versionRange, let udidRange {
                        let name = String(matchedString[nameRange])
                        let version = String(matchedString[versionRange])
                        let udid = String(matchedString[udidRange])

                        // Skip "My Mac" entries
                        guard !name.contains("My Mac") else { continue }

                        let device = Device(
                            id: udid,
                            name: name,
                            type: .physical,
                            state: .available,
                            runtime: nil,
                            osVersion: "iOS \(version)"
                        )
                        devices.append(device)
                    }
                }
            }
        }

        return devices
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
