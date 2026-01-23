import Foundation

/// Manages streaming console output from a running app
final class ConsoleStreamer: @unchecked Sendable {
    private var appProcess: Process?
    private var logStreamProcess: Process?

    /// Streams console output from a simulator app until stopped
    func streamSimulator(
        deviceId: String,
        bundleId: String,
        appName: String
    ) throws {
        // Print a visual separator before logs start
        print()
        print("─────────────────────────────────────────────────────────────────────".dim)
        print("Console Output".bold + " (Ctrl+C to stop)".dim)
        print("─────────────────────────────────────────────────────────────────────".dim)
        print()
        Terminal.flush()

        // Start OS log stream in the background for system logs
        // Use process name filter to capture app logs like Xcode does
        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        logProcess.arguments = [
            "simctl", "spawn", deviceId, "log", "stream",
            "--level", "debug",
            "--style", "compact",
            "--process", appName
        ]

        let logPipe = Pipe()
        logProcess.standardOutput = logPipe
        logProcess.standardError = logPipe

        logPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.printLogOutput(output, source: .osLog)
        }

        self.logStreamProcess = logProcess
        try logProcess.run()

        // Launch app with console output (this blocks until app terminates)
        let appProcess = Process()
        appProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        appProcess.arguments = ["simctl", "launch", "--console-pty", deviceId, bundleId]

        let appOutputPipe = Pipe()
        let appErrorPipe = Pipe()
        appProcess.standardOutput = appOutputPipe
        appProcess.standardError = appErrorPipe

        appOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.printLogOutput(output, source: .stdout)
        }

        appErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.printLogOutput(output, source: .stderr)
        }

        self.appProcess = appProcess
        try appProcess.run()

        // Wait for app to exit (or be terminated)
        appProcess.waitUntilExit()

        // Clean up
        stop()
    }

    /// Streams console output from a physical device app until stopped
    func streamPhysicalDevice(
        deviceId: String,
        bundleId: String
    ) throws {
        // Print a visual separator before logs start
        print()
        print("─────────────────────────────────────────────────────────────────────".dim)
        print("Console Output".bold + " (Ctrl+C to stop)".dim)
        print("─────────────────────────────────────────────────────────────────────".dim)
        print()
        Terminal.flush()

        // Launch app with console output
        let appProcess = Process()
        appProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        appProcess.arguments = [
            "devicectl", "device", "process", "launch",
            "--console",
            "--device", deviceId,
            bundleId
        ]

        let appOutputPipe = Pipe()
        let appErrorPipe = Pipe()
        appProcess.standardOutput = appOutputPipe
        appProcess.standardError = appErrorPipe

        appOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.printLogOutput(output, source: .stdout)
        }

        appErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.printLogOutput(output, source: .stderr)
        }

        self.appProcess = appProcess
        try appProcess.run()

        // Wait for app to exit (or be terminated)
        appProcess.waitUntilExit()

        // Clean up
        stop()
    }

    /// Streams console output from a Mac app until stopped
    func streamMacApp(
        appPath: String,
        bundleId: String
    ) throws {
        // Print a visual separator before logs start
        print()
        print("─────────────────────────────────────────────────────────────────────".dim)
        print("Console Output".bold + " (Ctrl+C to stop)".dim)
        print("─────────────────────────────────────────────────────────────────────".dim)
        print()
        Terminal.flush()

        // Extract app name for log filtering (the executable name inside the bundle)
        let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent

        // Launch the Mac app first so we can get its PID
        let appProcess = Process()
        appProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // Use -a to launch by app path, --stdout and --stderr to capture output
        appProcess.arguments = [appPath]

        appProcess.standardOutput = FileHandle.nullDevice
        appProcess.standardError = FileHandle.nullDevice

        self.appProcess = appProcess
        try appProcess.run()
        appProcess.waitUntilExit()

        // Give the app a moment to start
        Thread.sleep(forTimeInterval: 0.5)

        // Find the app's PID
        let pidProcess = Process()
        pidProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pidProcess.arguments = ["-x", appName]

        let pidPipe = Pipe()
        pidProcess.standardOutput = pidPipe
        pidProcess.standardError = FileHandle.nullDevice

        try pidProcess.run()
        pidProcess.waitUntilExit()

        let pidData = pidPipe.fileHandleForReading.readDataToEndOfFile()
        guard let pidString = String(data: pidData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int(pidString.components(separatedBy: .newlines).first ?? "") else {
            print("App launched but couldn't find its PID for log streaming.".yellow)
            print("App is running - press Ctrl+C to stop.".dim)
            // Wait indefinitely until Ctrl+C
            dispatchMain()
        }

        // Start OS log stream filtered by PID
        let logProcess = Process()
        logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        logProcess.arguments = [
            "stream",
            "--level", "info",
            "--style", "compact",
            "--predicate", "processIdentifier == \(pid)"
        ]

        let logPipe = Pipe()
        logProcess.standardOutput = logPipe
        logProcess.standardError = logPipe

        logPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.printLogOutput(output, source: .osLog)
        }

        self.logStreamProcess = logProcess
        try logProcess.run()

        // Wait until app exits or user presses Ctrl+C
        // Poll to check if app is still running
        while true {
            let checkProcess = Process()
            checkProcess.executableURL = URL(fileURLWithPath: "/bin/kill")
            checkProcess.arguments = ["-0", String(pid)]
            checkProcess.standardOutput = FileHandle.nullDevice
            checkProcess.standardError = FileHandle.nullDevice

            try? checkProcess.run()
            checkProcess.waitUntilExit()

            if checkProcess.terminationStatus != 0 {
                // Process no longer exists
                break
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        // Clean up
        stop()
    }

    /// Stops all streaming processes
    func stop() {
        if let process = logStreamProcess, process.isRunning {
            process.terminate()
        }
        logStreamProcess = nil

        if let process = appProcess, process.isRunning {
            process.terminate()
        }
        appProcess = nil
    }

    private enum LogSource {
        case stdout
        case stderr
        case osLog
    }

    private func printLogOutput(_ output: String, source: LogSource) {
        // Split into lines and print each
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            guard !line.isEmpty else { continue }
            let lineStr = String(line)

            // Skip the PID output line from simctl launch
            if lineStr.contains(": ") && lineStr.split(separator: ":").first?.allSatisfy({ $0.isNumber }) == true {
                continue
            }

            // Print short fixed-width divider above each log entry
            print("────────".dim)
            switch source {
            case .stdout:
                print(lineStr)
            case .stderr:
                print(lineStr.red)
            case .osLog:
                print(lineStr.dim)
            }
        }
        Terminal.flush()
    }
}

/// Global console streamer instance for signal handler access
var globalConsoleStreamer: ConsoleStreamer?

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
            case running
            case streaming
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
            case .running: return "▶️"
            case .streaming: return "📺"
            case .failed: return "❌"
            }
        }
    }

    // MARK: - Simulator

    func runOnSimulator(
        device: Device,
        appPath: String,
        bundleId: String,
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
        progress(RunProgress(phase: .launching, message: "Launching app..."))
        try await launchOnSimulator(deviceId: device.id, bundleId: bundleId)

        progress(RunProgress(phase: .running, message: "App is running on \(device.name)"))
    }

    /// Runs app on simulator with console output streaming until stopped
    func runOnSimulatorWithConsole(
        device: Device,
        appPath: String,
        bundleId: String,
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

        // Extract app name from path for log filtering
        let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent

        // Launch app with console streaming
        progress(RunProgress(phase: .streaming, message: "Streaming logs from \(device.name)... (Press Ctrl+C to stop)"))

        let streamer = ConsoleStreamer()
        globalConsoleStreamer = streamer

        try streamer.streamSimulator(
            deviceId: device.id,
            bundleId: bundleId,
            appName: appName
        )
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
        bundleId: String
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        let arguments = ["simctl", "launch", deviceId, bundleId]
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorMessage = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let message = errorMessage.isEmpty ? "Unknown error" : errorMessage
            throw RunError.launchFailed(message)
        }
    }

    // MARK: - Physical Device

    func runOnPhysicalDevice(
        device: Device,
        appPath: String,
        bundleId: String,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        // Check device connectivity first
        progress(RunProgress(phase: .checkingDevice, message: "Checking device connection..."))

        // Install using devicectl with progress monitoring
        progress(RunProgress(phase: .installing, message: "Installing app on \(device.name)..."))
        try await installOnPhysicalDevice(deviceId: device.id, appPath: appPath, progress: progress)

        // Launch using devicectl
        progress(RunProgress(phase: .launching, message: "Launching app..."))
        try await launchOnPhysicalDevice(
            deviceId: device.id,
            bundleId: bundleId,
            progress: progress
        )

        progress(RunProgress(phase: .running, message: "App is running on \(device.name)"))
    }

    /// Runs app on physical device with console output streaming until stopped
    func runOnPhysicalDeviceWithConsole(
        device: Device,
        appPath: String,
        bundleId: String,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        // Check device connectivity first
        progress(RunProgress(phase: .checkingDevice, message: "Checking device connection..."))

        // Install using devicectl with progress monitoring
        progress(RunProgress(phase: .installing, message: "Installing app on \(device.name)..."))
        try await installOnPhysicalDevice(deviceId: device.id, appPath: appPath, progress: progress)

        // Launch app with console streaming
        progress(RunProgress(phase: .streaming, message: "Streaming logs from \(device.name)... (Press Ctrl+C to stop)"))

        let streamer = ConsoleStreamer()
        globalConsoleStreamer = streamer

        try streamer.streamPhysicalDevice(
            deviceId: device.id,
            bundleId: bundleId
        )
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
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        func attemptLaunch() throws -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            let arguments = ["devicectl", "device", "process", "launch", "--device", deviceId, bundleId]
            process.arguments = arguments

            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus != 0 else { return nil }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            return errorMessage
        }

        if let errorMessage = try attemptLaunch() {
            if isDeviceLockedError(errorMessage) {
                try await waitForDeviceToBeReady(deviceId: deviceId, progress: progress)
                progress(RunProgress(phase: .launching, message: "Retrying launch..."))
                if let retryMessage = try attemptLaunch() {
                    if isDeviceLockedError(retryMessage) {
                        throw RunError.deviceNotReady("Please unlock your device to launch the app")
                    }
                    throw RunError.launchFailed(retryMessage.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                return
            }

            throw RunError.launchFailed(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func waitForDeviceToBeReady(
        deviceId: String,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        progress(RunProgress(phase: .waitingForUnlock, message: "Waiting for device to be unlocked..."))

        while true {
            try Task.checkCancellation()
            if try isDeviceReady(deviceId: deviceId) {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func isDeviceReady(deviceId: String) throws -> Bool {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-lockstate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "info", "lockState", "--device", deviceId, "--json-output", tempURL.path]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: tempURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any] else {
            return false
        }

        if let passcodeRequired = result["passcodeRequired"] as? Bool {
            return !passcodeRequired
        }
        if let locked = result["locked"] as? Bool {
            return !locked
        }
        if let state = result["state"] as? String {
            let normalized = state.lowercased()
            return normalized == "ready" || normalized == "unlocked"
        }
        if let status = result["status"] as? String {
            let normalized = status.lowercased()
            return normalized == "ready" || normalized == "unlocked"
        }
        return false
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

    private func isDeviceLockedError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("passcode") || lowercased.contains("locked") || lowercased.contains("unlock")
    }

    // MARK: - Mac

    func runOnMac(
        appPath: String,
        bundleId: String,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        progress(RunProgress(phase: .launching, message: "Launching app..."))

        // Simply open the app using the `open` command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath]

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw RunError.launchFailed(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        progress(RunProgress(phase: .running, message: "App is running"))
    }

    /// Runs Mac app with console output streaming
    func runOnMacWithConsole(
        appPath: String,
        bundleId: String,
        progress: @escaping (RunProgress) -> Void
    ) async throws {
        progress(RunProgress(phase: .streaming, message: "Streaming logs... (Press Ctrl+C to stop)"))

        let streamer = ConsoleStreamer()
        globalConsoleStreamer = streamer

        try streamer.streamMacApp(appPath: appPath, bundleId: bundleId)
    }

    // MARK: - Bundle ID Extraction

    static func extractBundleId(from appPath: String) -> String? {
        // Try iOS-style path first (Info.plist directly in .app)
        let iosInfoPlistPath = "\(appPath)/Info.plist"
        // Then try macOS-style path (Info.plist in Contents/)
        let macOSInfoPlistPath = "\(appPath)/Contents/Info.plist"

        let infoPlistPath: String
        if FileManager.default.fileExists(atPath: iosInfoPlistPath) {
            infoPlistPath = iosInfoPlistPath
        } else if FileManager.default.fileExists(atPath: macOSInfoPlistPath) {
            infoPlistPath = macOSInfoPlistPath
        } else {
            return nil
        }

        guard let data = FileManager.default.contents(atPath: infoPlistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String else {
            return nil
        }

        return bundleId
    }

}
