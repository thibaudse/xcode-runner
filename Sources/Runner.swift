import Foundation

/// Handles running apps on devices
actor AppRunner {

    enum RunError: LocalizedError {
        case deviceNotReady(String)
        case installFailed(String)
        case launchFailed(String)
        case noProductPath

        var errorDescription: String? {
            switch self {
            case .deviceNotReady(let reason): return "Device not ready: \(reason)"
            case .installFailed(let reason): return "Installation failed: \(reason)"
            case .launchFailed(let reason): return "Launch failed: \(reason)"
            case .noProductPath: return "No app to run"
            }
        }
    }

    struct RunProgress {
        let phase: Phase
        let message: String

        enum Phase {
            case checkingDevice
            case waitingForUnlock
            case preparingDevice
            case bootingDevice
            case installing
            case copying
            case verifying
            case launching
            case waitingForDebugger
            case running
            case failed
        }

        var icon: String {
            switch phase {
            case .checkingDevice: return "🔍"
            case .waitingForUnlock: return "🔐"
            case .preparingDevice: return "⚙️"
            case .bootingDevice: return "🔄"
            case .installing: return "📥"
            case .copying: return "📋"
            case .verifying: return "✓"
            case .launching: return "🚀"
            case .waitingForDebugger: return "🐞"
            case .running: return "▶️"
            case .failed: return "❌"
            }
        }
    }

    // MARK: - Simulator

    func runOnSimulator(
        device: Device,
        appPath: String,
        bundleId: String,
        waitForDebugger: Bool,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        // Boot simulator if needed
        if device.state != .booted {
            progress(RunProgress(phase: .bootingDevice, message: "Booting \(device.name)..."))
            try await bootSimulator(deviceId: device.id)
        }

        // Install app
        progress(RunProgress(phase: .installing, message: "Installing app..."))
        try await installOnSimulator(deviceId: device.id, appPath: appPath)

        // Launch app
        let launchMessage = waitForDebugger
            ? "Launching app (waiting for debugger)..."
            : "Launching app..."
        progress(RunProgress(phase: .launching, message: launchMessage))
        try await launchOnSimulator(deviceId: device.id, bundleId: bundleId, waitForDebugger: waitForDebugger)

        if waitForDebugger {
            progress(RunProgress(phase: .waitingForDebugger, message: "App is waiting for debugger on \(device.name)"))
        } else {
            progress(RunProgress(phase: .running, message: "App is running on \(device.name)"))
        }
    }

    private func bootSimulator(deviceId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "boot", deviceId]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        // Wait a bit for boot to complete
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Open Simulator app
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Simulator"]
        openProcess.standardOutput = FileHandle.nullDevice
        openProcess.standardError = FileHandle.nullDevice
        try openProcess.run()
        openProcess.waitUntilExit()

        // Wait for simulator to be ready
        try await Task.sleep(nanoseconds: 3_000_000_000)
    }

    private func installOnSimulator(deviceId: String, appPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "install", deviceId, appPath]

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw RunError.installFailed(errorMessage)
        }
    }

    private func launchOnSimulator(
        deviceId: String,
        bundleId: String,
        waitForDebugger: Bool
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["simctl", "launch"]
        if waitForDebugger {
            arguments.append("--wait-for-debugger")
        }
        arguments.append(deviceId)
        arguments.append(bundleId)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw RunError.launchFailed(errorMessage)
        }
    }

    // MARK: - Physical Device

    func runOnPhysicalDevice(
        device: Device,
        appPath: String,
        bundleId: String,
        waitForDebugger: Bool,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        // Check device connectivity first
        progress(RunProgress(phase: .checkingDevice, message: "Checking device connection..."))

        // Install using devicectl with progress monitoring
        progress(RunProgress(phase: .installing, message: "Installing app on \(device.name)..."))
        try await installOnPhysicalDevice(deviceId: device.id, appPath: appPath, progress: progress)

        // Launch using devicectl
        let launchMessage = waitForDebugger
            ? "Launching app (waiting for debugger)..."
            : "Launching app..."
        progress(RunProgress(phase: .launching, message: launchMessage))
        try await launchOnPhysicalDevice(
            deviceId: device.id,
            bundleId: bundleId,
            waitForDebugger: waitForDebugger,
            progress: progress
        )

        if waitForDebugger {
            progress(RunProgress(phase: .waitingForDebugger, message: "App is waiting for debugger on \(device.name)"))
        } else {
            progress(RunProgress(phase: .running, message: "App is running on \(device.name)"))
        }
    }

    private func installOnPhysicalDevice(
        deviceId: String,
        appPath: String,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "install", "app", "--device", deviceId, appPath]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Monitor output for progress messages
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self.parseDeviceOutput(output, progress: progress)
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self.parseDeviceOutput(output, progress: progress)
        }

        try process.run()
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            // Provide helpful messages for common errors
            if errorMessage.contains("passcode") || errorMessage.contains("locked") || errorMessage.contains("unlock") {
                throw RunError.deviceNotReady("Please unlock your device and try again")
            } else if errorMessage.contains("trust") || errorMessage.contains("Trust") {
                throw RunError.deviceNotReady("Please trust this computer on your device")
            } else if errorMessage.contains("Developer Mode") || errorMessage.contains("developer mode") {
                throw RunError.deviceNotReady("Please enable Developer Mode in Settings > Privacy & Security")
            } else if errorMessage.contains("provision") || errorMessage.contains("signing") {
                throw RunError.installFailed("Code signing error - check your provisioning profile")
            }

            throw RunError.installFailed(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func launchOnPhysicalDevice(
        deviceId: String,
        bundleId: String,
        waitForDebugger: Bool,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["devicectl", "device", "process", "launch", "--device", deviceId]
        if waitForDebugger {
            arguments.append("--start-stopped")
        }
        arguments.append(bundleId)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            if errorMessage.contains("passcode") || errorMessage.contains("locked") || errorMessage.contains("unlock") {
                throw RunError.deviceNotReady("Please unlock your device to launch the app")
            }

            throw RunError.launchFailed(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private nonisolated func parseDeviceOutput(_ output: String, progress: @escaping (RunProgress) -> Void) {
        let lowercased = output.lowercased()

        if lowercased.contains("unlock") || lowercased.contains("passcode") || lowercased.contains("locked") {
            progress(RunProgress(phase: .waitingForUnlock, message: "Waiting for device to be unlocked..."))
        } else if lowercased.contains("preparing") || lowercased.contains("prepare") {
            progress(RunProgress(phase: .preparingDevice, message: "Preparing device..."))
        } else if lowercased.contains("copying") || lowercased.contains("transferring") {
            progress(RunProgress(phase: .copying, message: "Copying app to device..."))
        } else if lowercased.contains("verifying") || lowercased.contains("verify") {
            progress(RunProgress(phase: .verifying, message: "Verifying installation..."))
        } else if lowercased.contains("installing") {
            progress(RunProgress(phase: .installing, message: "Installing app..."))
        }
    }

    // MARK: - Bundle ID Extraction

    static func extractBundleId(from appPath: String) -> String? {
        let infoPlistPath = "\(appPath)/Info.plist"

        guard let data = FileManager.default.contents(atPath: infoPlistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else {
            return nil
        }

        return bundleId
    }
}
