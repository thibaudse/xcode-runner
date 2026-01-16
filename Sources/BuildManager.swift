import Foundation

/// Build progress information
struct BuildProgress {
    let phase: Phase
    let percentage: Double
    let message: String
    let detail: String?

    enum Phase: String {
        case preparing = "Preparing"
        case compiling = "Compiling"
        case linking = "Linking"
        case signing = "Signing"
        case copying = "Copying"
        case processing = "Processing"
        case succeeded = "Build Succeeded"
        case failed = "Build Failed"

        // Device-related phases
        case waitingForDevice = "Waiting for Device"
        case preparingDevice = "Preparing Device"
        case registeringDevice = "Registering Device"

        var icon: String {
            switch self {
            case .preparing: return "⏳"
            case .compiling: return "🔨"
            case .linking: return "🔗"
            case .signing: return "🔏"
            case .copying: return "📋"
            case .processing: return "⚙️"
            case .succeeded: return "✅"
            case .failed: return "❌"
            case .waitingForDevice: return "🔐"
            case .preparingDevice: return "📱"
            case .registeringDevice: return "📝"
            }
        }
    }
}

/// Manages the build process
actor BuildManager {
    private var process: Process?

    struct BuildConfiguration {
        let project: XcodeProject
        let scheme: String
        let device: Device
        let configuration: String
        let verbose: Bool

        init(project: XcodeProject, scheme: String, device: Device, configuration: String = "Debug", verbose: Bool = false) {
            self.project = project
            self.scheme = scheme
            self.device = device
            self.configuration = configuration
            self.verbose = verbose
        }
    }

    struct BuildResult {
        let success: Bool
        let productPath: String?
        let errors: [String]
        let warnings: [String]
        let duration: TimeInterval
    }

    // MARK: - Building

    func build(config: BuildConfiguration, progress: @escaping (BuildProgress) -> Void) async throws -> BuildResult {
        let startTime = Date()

        // Report initial progress
        progress(BuildProgress(phase: .preparing, percentage: 0, message: "Preparing build...", detail: nil))

        // Boot simulator if needed (helps avoid "Unable to find device" errors)
        if config.device.type == .simulator && config.device.state != .booted {
            progress(BuildProgress(phase: .preparingDevice, percentage: 5, message: "Booting simulator...", detail: nil))
            await bootSimulatorIfNeeded(deviceId: config.device.id)
        }

        // Use persistent derived data path for incremental builds
        let projectHash = config.project.path.path.hash
        let derivedDataPath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("xcode-runner")
            .appendingPathComponent("\(config.project.name)-\(abs(projectHash))")
            .path

        // Create cache directory if needed
        try? FileManager.default.createDirectory(atPath: derivedDataPath, withIntermediateDirectories: true)

        var arguments = [
            config.project.type.flag, config.project.path.path,
            "-scheme", config.scheme,
            "-configuration", config.configuration,
            "-derivedDataPath", derivedDataPath,
            "-parallelizeTargets",
            "-allowProvisioningUpdates",
        ]

        // Add destination based on device type
        let destination: String
        switch config.device.type {
        case .simulator:
            destination = "platform=iOS Simulator,id=\(config.device.id)"
        case .physical:
            destination = "platform=iOS,id=\(config.device.id)"
        }
        arguments += ["-destination", destination]

        arguments.append("build")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process

        let isVerbose = config.verbose
        let collector = BuildOutputCollector(progress: progress)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let output = String(data: data, encoding: .utf8) {
                // Print raw output in verbose mode
                if isVerbose {
                    print(output, terminator: "")
                }

                collector.handleStdout(output)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else { return }

            // Print raw error output in verbose mode
            if isVerbose {
                print(output.red, terminator: "")
            }

            collector.handleStderr(output)
        }

        try process.run()
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        // Drain any remaining output after the process exits
        let remainingOut = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: remainingOut, encoding: .utf8), !output.isEmpty {
            if isVerbose {
                print(output, terminator: "")
            }
            collector.handleStdout(output)
        }

        let remainingErr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: remainingErr, encoding: .utf8), !output.isEmpty {
            if isVerbose {
                print(output.red, terminator: "")
            }
            collector.handleStderr(output)
        }

        let success = process.terminationStatus == 0
        let duration = Date().timeIntervalSince(startTime)
        let snapshot = collector.snapshot()

        if success {
            progress(BuildProgress(phase: .succeeded, percentage: 100, message: "Build succeeded!", detail: nil))
        } else {
            progress(BuildProgress(phase: .failed, percentage: 100, message: "Build failed", detail: snapshot.errors.first))
        }

        // Find the built product
        var finalProductPath = snapshot.productPath
        if finalProductPath == nil && success {
            finalProductPath = findBuiltProduct(in: derivedDataPath, scheme: config.scheme)
        }

        return BuildResult(
            success: success,
            productPath: finalProductPath,
            errors: snapshot.errors,
            warnings: snapshot.warnings,
            duration: duration
        )
    }

    private func findBuiltProduct(in derivedDataPath: String, scheme: String) -> String? {
        let productsPath = "\(derivedDataPath)/Build/Products"
        let fm = FileManager.default

        // Check all possible configuration/platform combinations
        let configurations = ["Debug", "Release"]
        let platforms = ["iphoneos", "iphonesimulator"]

        for config in configurations {
            for platform in platforms {
                let productDir = "\(productsPath)/\(config)-\(platform)"

                // First try exact scheme name match
                let exactPath = "\(productDir)/\(scheme).app"
                if fm.fileExists(atPath: exactPath) {
                    return exactPath
                }

                // Search for any .app in this directory
                if let contents = try? fm.contentsOfDirectory(atPath: productDir) {
                    for item in contents where item.hasSuffix(".app") {
                        return "\(productDir)/\(item)"
                    }
                }
            }
        }

        // Fallback: search recursively for any .app bundle
        if let enumerator = fm.enumerator(atPath: productsPath) {
            while let file = enumerator.nextObject() as? String {
                if file.hasSuffix(".app") {
                    let fullPath = "\(productsPath)/\(file)"
                    // Make sure it's a directory (app bundle) not a file
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        return fullPath
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Simulator Management

    private func bootSimulatorIfNeeded(deviceId: String) async {
        // Check if already booted
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        checkProcess.arguments = ["simctl", "list", "devices", "-j"]

        let checkPipe = Pipe()
        checkProcess.standardOutput = checkPipe
        checkProcess.standardError = FileHandle.nullDevice

        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()

            let data = checkPipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [String: [[String: Any]]] {
                for (_, deviceList) in devices {
                    for device in deviceList {
                        if let udid = device["udid"] as? String,
                           udid == deviceId,
                           let state = device["state"] as? String,
                           state == "Booted" {
                            return // Already booted
                        }
                    }
                }
            }
        } catch {
            // Continue to boot anyway
        }

        // Boot the simulator
        let bootProcess = Process()
        bootProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        bootProcess.arguments = ["simctl", "boot", deviceId]
        bootProcess.standardOutput = FileHandle.nullDevice
        bootProcess.standardError = FileHandle.nullDevice

        do {
            try bootProcess.run()
            bootProcess.waitUntilExit()

            // Give it a moment to fully boot
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            // Ignore boot errors - xcodebuild will handle it
        }
    }

    // MARK: - Cancel

    func cancel() {
        process?.terminate()
    }
}

// MARK: - Output Collection

private struct BuildOutputSnapshot {
    let errors: [String]
    let warnings: [String]
    let productPath: String?
}

private final class BuildOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: (BuildProgress) -> Void

    private var totalFiles = 0
    private var compiledFiles = 0
    private var productPath: String?
    private var errors: [String] = []
    private var warnings: [String] = []
    private var outputLines: [String] = []

    init(progress: @escaping (BuildProgress) -> Void) {
        self.progress = progress
    }

    func handleStdout(_ output: String) {
        var updates: [BuildProgress] = []

        lock.lock()
        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            outputLines.append(line)

            if line.contains("Compiling") || line.hasPrefix("CompileC") || line.hasPrefix("CompileSwift") {
                compiledFiles += 1
                let percentage = totalFiles > 0 ? Double(compiledFiles) / Double(totalFiles) * 80 : 50
                let filename = extractFilename(from: line) ?? "source files"
                updates.append(BuildProgress(
                    phase: .compiling,
                    percentage: min(percentage, 80),
                    message: "Compiling \(filename)",
                    detail: nil
                ))
            } else if line.contains("Linking") || line.hasPrefix("Ld") {
                updates.append(BuildProgress(
                    phase: .linking,
                    percentage: 85,
                    message: "Linking...",
                    detail: nil
                ))
            } else if line.contains("CodeSign") || line.contains("Signing") {
                updates.append(BuildProgress(
                    phase: .signing,
                    percentage: 90,
                    message: "Signing...",
                    detail: nil
                ))
            } else if line.contains("CopySwiftLibs") || line.contains("Copy") {
                updates.append(BuildProgress(
                    phase: .copying,
                    percentage: 95,
                    message: "Copying resources...",
                    detail: nil
                ))
            } else if line.contains("BUILD SUCCEEDED") {
                updates.append(BuildProgress(
                    phase: .succeeded,
                    percentage: 100,
                    message: "Build succeeded!",
                    detail: nil
                ))
            } else if line.contains("BUILD FAILED") {
                updates.append(BuildProgress(
                    phase: .failed,
                    percentage: 100,
                    message: "Build failed",
                    detail: nil
                ))
            }

            let lowercased = line.lowercased()
            if lowercased.contains("passcode protected") || lowercased.contains("device is locked") {
                updates.append(BuildProgress(
                    phase: .waitingForDevice,
                    percentage: 50,
                    message: "🔐 Device is locked - please unlock your device",
                    detail: nil
                ))
            } else if lowercased.contains("waiting") && (lowercased.contains("device") || lowercased.contains("unlock")) {
                updates.append(BuildProgress(
                    phase: .waitingForDevice,
                    percentage: 50,
                    message: "Waiting for device - please unlock if needed",
                    detail: nil
                ))
            } else if lowercased.contains("preparing") && lowercased.contains("device") {
                updates.append(BuildProgress(
                    phase: .preparingDevice,
                    percentage: 50,
                    message: "Preparing device for development...",
                    detail: nil
                ))
            } else if lowercased.contains("register") && lowercased.contains("device") {
                updates.append(BuildProgress(
                    phase: .registeringDevice,
                    percentage: 50,
                    message: "Registering device...",
                    detail: nil
                ))
            }

            if line.contains(".app") && line.contains("Build/Products") {
                if let range = line.range(of: #"[^\s]+\.app"#, options: .regularExpression) {
                    productPath = String(line[range])
                }
            }
        }
        lock.unlock()

        for update in updates {
            progress(update)
        }
    }

    func handleStderr(_ output: String) {
        lock.lock()
        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            if line.contains("error:") {
                errors.append(line)
            } else if line.contains("warning:") {
                warnings.append(line)
            }
        }
        lock.unlock()
    }

    func snapshot() -> BuildOutputSnapshot {
        lock.lock()
        let snapshot = BuildOutputSnapshot(errors: errors, warnings: warnings, productPath: productPath)
        lock.unlock()
        return snapshot
    }

    private func extractFilename(from line: String) -> String? {
        if let range = line.range(of: #"\w+\.(swift|m|mm|c|cpp)"#, options: .regularExpression) {
            return String(line[range])
        }
        return nil
    }
}
