import Foundation

/// Build progress information
struct BuildProgress {
    let phase: Phase
    let percentage: Double
    let message: String
    let detail: String?

    enum Phase: String {
        case preparing = "Preparing"
        case resolvingPackages = "Resolving Packages"
        case fetchingPackages = "Fetching Packages"
        case updatingPackages = "Updating Packages"
        case checkingOutPackages = "Checking Out Packages"
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
            case .resolvingPackages: return "📦"
            case .fetchingPackages: return "⬇️"
            case .updatingPackages: return "🔄"
            case .checkingOutPackages: return "🔖"
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

        // Use Xcode's DerivedData location to share package caches with Xcode
        let derivedDataPath = resolveDerivedDataPath(config: config, progress: progress)

        // Create derived data directory if needed
        try? FileManager.default.createDirectory(atPath: derivedDataPath, withIntermediateDirectories: true)

        var arguments = [
            config.project.type.flag, config.project.path.path,
            "-scheme", config.scheme,
            "-configuration", config.configuration,
            "-parallelizeTargets",
            "-allowProvisioningUpdates",
        ]
        arguments += ["-derivedDataPath", derivedDataPath]

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
        if let path = finalProductPath {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
                finalProductPath = nil
            }
        }
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
            let didFinish = waitForProcess(checkProcess, timeout: 3)
            if didFinish {
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
            _ = waitForProcess(bootProcess, timeout: 8)

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

    private func resolveDerivedDataPath(config: BuildConfiguration, progress: @escaping (BuildProgress) -> Void) -> String {
        let root = xcodeDerivedDataRoot()
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        let projectPath = config.project.path.path
        let projectName = config.project.name

        if let existing = findXcodeDerivedData(for: projectPath, projectName: projectName, root: root) {
            if isDerivedDataCorrupted(at: existing) {
                progress(BuildProgress(
                    phase: .processing,
                    percentage: 2,
                    message: "Existing Xcode derived data looks corrupted, using a fresh folder...",
                    detail: nil
                ))
            } else {
                return existing
            }
        }

        let fallback = "\(root)/\(projectName)-\(stableHash(for: projectPath))"
        if isDerivedDataCorrupted(at: fallback) {
            progress(BuildProgress(
                phase: .processing,
                percentage: 2,
                message: "Cleaning derived data (corrupted package state)...",
                detail: nil
            ))
            try? fm.removeItem(atPath: fallback)
        }

        return fallback
    }

    private func xcodeDerivedDataRoot() -> String {
        let fm = FileManager.default
        let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return libraryURL.appendingPathComponent("Developer/Xcode/DerivedData").path
    }

    private func findXcodeDerivedData(for projectPath: String, projectName: String, root: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }

        let normalizedPath = URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path
        let fileURLPath = URL(fileURLWithPath: projectPath).absoluteString
        let candidates = entries.filter { $0.hasPrefix("\(projectName)-") }

        var bestMatch: (path: String, modified: Date) = ("", .distantPast)
        for entry in candidates {
            let derivedPath = "\(root)/\(entry)"
            let infoPath = "\(derivedPath)/info.plist"

            guard let data = fm.contents(atPath: infoPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                continue
            }

            if plistContainsPath(plist, paths: [projectPath, normalizedPath, fileURLPath]) {
                let attrs = (try? fm.attributesOfItem(atPath: derivedPath)) ?? [:]
                let modified = attrs[.modificationDate] as? Date ?? .distantPast
                if modified > bestMatch.modified {
                    bestMatch = (derivedPath, modified)
                }
            }
        }

        return bestMatch.path.isEmpty ? nil : bestMatch.path
    }

    private func plistContainsPath(_ value: Any, paths: [String]) -> Bool {
        if let string = value as? String {
            return paths.contains(where: { string.contains($0) })
        }
        if let dict = value as? [String: Any] {
            return dict.values.contains(where: { plistContainsPath($0, paths: paths) })
        }
        if let array = value as? [Any] {
            return array.contains(where: { plistContainsPath($0, paths: paths) })
        }
        return false
    }

    private func isDerivedDataCorrupted(at path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return true }

        let sourcePackagesPath = "\(path)/SourcePackages"
        guard fm.fileExists(atPath: sourcePackagesPath, isDirectory: &isDir) else { return false }
        if !isDir.boolValue { return true }

        let workspaceStatePath = "\(sourcePackagesPath)/workspace-state.json"
        guard fm.fileExists(atPath: workspaceStatePath) else { return false }
        guard let data = fm.contents(atPath: workspaceStatePath) else { return true }

        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            return true
        }

        return false
    }

    private func stableHash(for value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private func waitForProcess(_ process: Process, timeout: TimeInterval) -> Bool {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }

        let result = group.wait(timeout: .now() + timeout)
        if result == .timedOut {
            process.terminate()
            return false
        }
        return true
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
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()

            if lowercased == "resolve package graph" || lowercased.contains("resolving package graph") {
                updates.append(BuildProgress(
                    phase: .resolvingPackages,
                    percentage: 5,
                    message: "Resolving package graph...",
                    detail: nil
                ))
            } else if lowercased.hasPrefix("fetching ") || lowercased.hasPrefix("cloning ") {
                updates.append(BuildProgress(
                    phase: .fetchingPackages,
                    percentage: 10,
                    message: packageMessage(prefix: "Fetching", line: trimmed),
                    detail: nil
                ))
            } else if lowercased.hasPrefix("updating ") {
                updates.append(BuildProgress(
                    phase: .updatingPackages,
                    percentage: 10,
                    message: packageMessage(prefix: "Updating", line: trimmed),
                    detail: nil
                ))
            } else if lowercased.contains("checking out") {
                updates.append(BuildProgress(
                    phase: .checkingOutPackages,
                    percentage: 12,
                    message: packageMessage(prefix: "Checking out", line: trimmed),
                    detail: nil
                ))
            } else if lowercased.contains("resolved source packages") {
                updates.append(BuildProgress(
                    phase: .resolvingPackages,
                    percentage: 15,
                    message: "Resolved source packages",
                    detail: nil
                ))
            } else if lowercased.contains("compute dependency graph") || lowercased.contains("computing dependency graph") {
                updates.append(BuildProgress(
                    phase: .processing,
                    percentage: 20,
                    message: "Computing dependency graph...",
                    detail: nil
                ))
            } else if lowercased.contains("create build description") || lowercased.contains("creating build description") {
                updates.append(BuildProgress(
                    phase: .processing,
                    percentage: 25,
                    message: "Creating build description...",
                    detail: nil
                ))
            }

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

            if line.contains(".app") {
                if let appPath = extractAppPath(from: line) {
                    productPath = appPath
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

    private func extractAppPath(from line: String) -> String? {
        if let path = extractAppPathFromBuildProducts(line) {
            return path
        }

        if let range = line.range(of: #"/[^\n]*?\.app"#, options: .regularExpression) {
            return String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return nil
    }

    private func extractAppPathFromBuildProducts(_ line: String) -> String? {
        guard let buildRange = line.range(of: "Build/Products") else { return nil }

        let prefix = line[..<buildRange.lowerBound]
        let startIndex = prefix.lastIndex(where: { $0 == " " || $0 == "\t" })
            .map { line.index(after: $0) } ?? line.startIndex

        guard let appRange = line[buildRange.lowerBound...].range(of: ".app") else { return nil }

        let path = String(line[startIndex..<appRange.upperBound])
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func packageMessage(prefix: String, line: String) -> String {
        if let name = extractPackageName(from: line) {
            return "\(prefix) \(name)..."
        }
        return "\(prefix) packages..."
    }

    private func extractPackageName(from line: String) -> String? {
        if let url = extractURL(from: line) {
            return shortRepoName(from: url)
        }

        if let range = line.range(of: "package ") {
            let name = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        return nil
    }

    private func extractURL(from line: String) -> String? {
        if let range = line.range(of: #"https?://\S+"#, options: .regularExpression) {
            return String(line[range])
        }
        if let range = line.range(of: #"git@\S+"#, options: .regularExpression) {
            return String(line[range])
        }
        return nil
    }

    private func shortRepoName(from url: String) -> String {
        var cleaned = url
        while let last = cleaned.last, ".,)]".contains(last) {
            cleaned.removeLast()
        }

        if cleaned.hasPrefix("git@") {
            if let colon = cleaned.firstIndex(of: ":") {
                cleaned = String(cleaned[cleaned.index(after: colon)...])
            }
        } else if let schemeRange = cleaned.range(of: "://") {
            cleaned = String(cleaned[schemeRange.upperBound...])
            if let slash = cleaned.firstIndex(of: "/") {
                cleaned = String(cleaned[cleaned.index(after: slash)...])
            }
        }

        if cleaned.hasSuffix(".git") {
            cleaned.removeLast(4)
        }

        let parts = cleaned.split(separator: "/")
        if parts.count >= 2 {
            let owner = parts[parts.count - 2]
            let repo = parts[parts.count - 1]
            return "\(owner)/\(repo)"
        }

        return cleaned
    }
}
