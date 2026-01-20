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
}
