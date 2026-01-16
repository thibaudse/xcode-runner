import Foundation

/// Represents an Xcode project or workspace
struct XcodeProject {
    let path: URL
    let type: ProjectType
    let name: String
    let schemes: [String]

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
            if let project = try? loadProject(at: url, type: .workspace) {
                projects.append(project)
            }
        }

        // Then look for project files
        for url in contents where url.pathExtension == "xcodeproj" {
            if let project = try? loadProject(at: url, type: .project) {
                projects.append(project)
            }
        }

        return projects
    }

    private func loadProject(at url: URL, type: XcodeProject.ProjectType) throws -> XcodeProject {
        let name = url.deletingPathExtension().lastPathComponent
        let schemes = try discoverSchemes(for: url, type: type)

        return XcodeProject(
            path: url,
            type: type,
            name: name,
            schemes: schemes
        )
    }

    // MARK: - Schemes

    func discoverSchemes(for projectURL: URL, type: XcodeProject.ProjectType) throws -> [String] {
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
        return response.workspace?.schemes ?? response.project?.schemes ?? []
    }
}
