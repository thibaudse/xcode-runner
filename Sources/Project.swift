import Foundation

/// Represents an Xcode project or workspace
class XcodeProject {
    let path: URL
    let type: ProjectType
    let name: String

    /// Schemes are loaded lazily to avoid slow xcodebuild -list calls when not needed
    private var _schemes: [String]?
    var schemes: [String] {
        if let cached = _schemes {
            return cached
        }
        let loaded = (try? ProjectManager().discoverSchemes(for: path, type: type)) ?? []
        _schemes = loaded
        return loaded
    }

    init(path: URL, type: ProjectType, name: String) {
        self.path = path
        self.type = type
        self.name = name
    }

    enum ProjectType {
        case workspace
        case project

        var flag: String {
            switch self {
            case .workspace: return "-workspace"
            case .project: return "-project"
            }
        }

        var icon: String {
            switch self {
            case .workspace: return "📦"
            case .project: return "📁"
            }
        }
    }

    var displayName: String {
        "\(type.icon) \(name)"
    }
}

/// Discovers and manages Xcode projects
struct ProjectManager {
    let workingDirectory: URL

    init(workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - Discovery

    func discoverProjects() throws -> [XcodeProject] {
        let fileManager = FileManager.default
        var projects: [XcodeProject] = []

        let contents = try fileManager.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Look for workspaces first (they take precedence)
        for url in contents where url.pathExtension == "xcworkspace" {
            projects.append(loadProject(at: url, type: .workspace))
        }

        // Then look for project files
        for url in contents where url.pathExtension == "xcodeproj" {
            projects.append(loadProject(at: url, type: .project))
        }

        return projects
    }

    private func loadProject(at url: URL, type: XcodeProject.ProjectType) -> XcodeProject {
        let name = url.deletingPathExtension().lastPathComponent
        // Schemes are loaded lazily when first accessed
        return XcodeProject(path: url, type: type, name: name)
    }

    // MARK: - Schemes

    func discoverSchemes(for projectURL: URL, type: XcodeProject.ProjectType) throws -> [String] {
        let cacheKey = projectURL.path
        let signature = SchemeSignatureBuilder.signature(for: projectURL, type: type)

        if let cachedSchemes = SchemeCacheStore.shared.cachedSchemes(for: cacheKey, signature: signature) {
            return cachedSchemes
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            type.flag, projectURL.path,
            "-list",
            "-json"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        struct ListResponse: Decodable {
            let workspace: WorkspaceInfo?
            let project: ProjectInfo?

            struct WorkspaceInfo: Decodable {
                let schemes: [String]
            }

            struct ProjectInfo: Decodable {
                let schemes: [String]
            }
        }

        let response = try JSONDecoder().decode(ListResponse.self, from: data)
        let schemes = response.workspace?.schemes ?? response.project?.schemes ?? []
        SchemeCacheStore.shared.storeSchemes(schemes, for: cacheKey, signature: signature)
        return schemes
    }

    // MARK: - Destinations

    /// Supported destination platforms for a scheme
    struct SchemeDestinations {
        var supportsiOS: Bool = false
        var supportsmacOS: Bool = false
        var supportswatchOS: Bool = false
        var supportstvOS: Bool = false
        var supportsvisionOS: Bool = false

        func supports(_ platform: Device.Platform) -> Bool {
            switch platform {
            case .iOS: return supportsiOS
            case .macOS: return supportsmacOS
            case .watchOS: return supportswatchOS
            case .tvOS: return supportstvOS
            case .visionOS: return supportsvisionOS
            }
        }
    }

    /// Discovers the supported destinations for a scheme
    func discoverDestinations(for project: XcodeProject, scheme: String) -> SchemeDestinations {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            project.type.flag, project.path.path,
            "-scheme", scheme,
            "-showdestinations"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // If we can't query destinations, allow all platforms
            return SchemeDestinations(
                supportsiOS: true,
                supportsmacOS: true,
                supportswatchOS: true,
                supportstvOS: true,
                supportsvisionOS: true
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return SchemeDestinations(
                supportsiOS: true,
                supportsmacOS: true,
                supportswatchOS: true,
                supportstvOS: true,
                supportsvisionOS: true
            )
        }

        // Parse output to determine supported platforms
        // Format: { platform:iOS Simulator, id:..., OS:17.0, name:iPhone 15 }
        //         { platform:macOS, arch:arm64 }
        //         { platform:iOS, id:..., name:... }
        var destinations = SchemeDestinations()

        let lowercased = output.lowercased()

        // Check for iOS support (including Mac Catalyst)
        if lowercased.contains("platform:ios") ||
           lowercased.contains("platform:ios simulator") ||
           lowercased.contains("platform:mac catalyst") {
            destinations.supportsiOS = true
        }

        // Check for macOS support
        if lowercased.contains("platform:macos") ||
           lowercased.contains("platform:mac catalyst") {
            destinations.supportsmacOS = true
        }

        // Check for watchOS support
        if lowercased.contains("platform:watchos") ||
           lowercased.contains("platform:watchos simulator") {
            destinations.supportswatchOS = true
        }

        // Check for tvOS support
        if lowercased.contains("platform:tvos") ||
           lowercased.contains("platform:tvos simulator") {
            destinations.supportstvOS = true
        }

        // Check for visionOS support
        if lowercased.contains("platform:visionos") ||
           lowercased.contains("platform:visionos simulator") ||
           lowercased.contains("platform:xros") {
            destinations.supportsvisionOS = true
        }

        return destinations
    }
}
