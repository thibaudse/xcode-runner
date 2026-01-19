import Foundation

final class SchemeCacheStore {
    static let shared = SchemeCacheStore()

    private static let userDefaultsKey = "xcode-runner.scheme-cache"
    private static let userDefaults: UserDefaults = {
        UserDefaults(suiteName: "xcode-runner") ?? .standard
    }()

    private let fallbackTTL: TimeInterval = 10 * 60
    private let maxEntries: Int = 50

    private var data: SchemeCacheData

    private init() {
        if let loaded = Self.loadFromUserDefaults() {
            data = loaded
        } else {
            data = SchemeCacheData(entries: [:])
        }
    }

    func cachedSchemes(for key: String, signature: Date?) -> [String]? {
        guard let entry = data.entries[key] else { return nil }

        if let signature, let stored = entry.signature {
            let current = signature.timeIntervalSince1970
            if abs(stored - current) < 0.001 {
                return entry.schemes
            }
            return nil
        }

        if signature == nil {
            let now = Date().timeIntervalSince1970
            if now - entry.cachedAt < fallbackTTL {
                return entry.schemes
            }
        }

        return nil
    }

    func storeSchemes(_ schemes: [String], for key: String, signature: Date?) {
        data.entries[key] = SchemeCacheEntry(
            schemes: schemes,
            signature: signature?.timeIntervalSince1970,
            cachedAt: Date().timeIntervalSince1970
        )

        if data.entries.count > maxEntries {
            let overflow = data.entries.count - maxEntries
            let sorted = data.entries.sorted { $0.value.cachedAt < $1.value.cachedAt }
            for (key, _) in sorted.prefix(overflow) {
                data.entries.removeValue(forKey: key)
            }
        }

        save()
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        Self.userDefaults.set(encoded, forKey: Self.userDefaultsKey)
        Self.userDefaults.synchronize()
    }

    private static func loadFromUserDefaults() -> SchemeCacheData? {
        guard let data = userDefaults.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(SchemeCacheData.self, from: data)
    }
}

struct SchemeSignatureBuilder {
    static func signature(for projectURL: URL, type: XcodeProject.ProjectType) -> Date? {
        switch type {
        case .project:
            return projectSignature(for: projectURL)
        case .workspace:
            return workspaceSignature(for: projectURL)
        }
    }

    private static func projectSignature(for projectURL: URL) -> Date? {
        var dates = [Date]()
        let pbxprojURL = projectURL.appendingPathComponent("project.pbxproj")
        if let date = modificationDate(at: pbxprojURL) {
            dates.append(date)
        }
        dates.append(contentsOf: schemeFileDates(in: projectURL))
        if dates.isEmpty, let fallback = modificationDate(at: projectURL) {
            dates.append(fallback)
        }
        return dates.max()
    }

    private static func workspaceSignature(for workspaceURL: URL) -> Date? {
        var dates = [Date]()
        let contentsURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata")
        if let date = modificationDate(at: contentsURL) {
            dates.append(date)
        }
        dates.append(contentsOf: schemeFileDates(in: workspaceURL))

        let referencedProjects = referencedProjectURLs(in: workspaceURL)
        for projectURL in referencedProjects {
            if let projectSignature = projectSignature(for: projectURL) {
                dates.append(projectSignature)
            }
        }

        if dates.isEmpty, let fallback = modificationDate(at: workspaceURL) {
            dates.append(fallback)
        }

        return dates.max()
    }

    private static func schemeFileDates(in containerURL: URL) -> [Date] {
        var dates: [Date] = []
        for schemeDir in schemeDirectories(in: containerURL) {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: schemeDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for fileURL in files where fileURL.pathExtension == "xcscheme" {
                    if let date = modificationDate(at: fileURL) {
                        dates.append(date)
                    }
                }
            }
        }
        return dates
    }

    private static func schemeDirectories(in containerURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = []

        let sharedSchemes = containerURL.appendingPathComponent("xcshareddata/xcschemes")
        if fileManager.fileExists(atPath: sharedSchemes.path) {
            directories.append(sharedSchemes)
        }

        let userData = containerURL.appendingPathComponent("xcuserdata")
        guard let users = try? fileManager.contentsOfDirectory(
            at: userData,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return directories
        }

        for userDir in users {
            let xcschemes = userDir.appendingPathComponent("xcschemes")
            if fileManager.fileExists(atPath: xcschemes.path) {
                directories.append(xcschemes)
            }
        }

        return directories
    }

    private static func referencedProjectURLs(in workspaceURL: URL) -> [URL] {
        let contentsURL = workspaceURL.appendingPathComponent("contents.xcworkspacedata")
        guard let data = try? Data(contentsOf: contentsURL),
              let xml = String(data: data, encoding: .utf8) else {
            return []
        }

        let pattern = #"location\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(xml.startIndex..., in: xml)
        let baseURL = workspaceURL.deletingLastPathComponent()
        var projects: [URL] = []

        for match in regex.matches(in: xml, range: range) {
            guard let locationRange = Range(match.range(at: 1), in: xml) else { continue }
            let location = String(xml[locationRange])
            guard let resolved = resolveFileRef(location, baseURL: baseURL) else { continue }
            if resolved.pathExtension == "xcodeproj" {
                projects.append(resolved.standardizedFileURL)
            }
        }

        return Array(Set(projects))
    }

    private static func resolveFileRef(_ location: String, baseURL: URL) -> URL? {
        let parts = location.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let scheme = parts[0]
            let path = String(parts[1])
            switch scheme {
            case "absolute", "file":
                return URL(fileURLWithPath: path)
            case "group", "container":
                return baseURL.appendingPathComponent(path).standardizedFileURL
            case "self":
                return baseURL
            default:
                return baseURL.appendingPathComponent(location).standardizedFileURL
            }
        }

        return baseURL.appendingPathComponent(location).standardizedFileURL
    }

    private static func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

private struct SchemeCacheData: Codable {
    var entries: [String: SchemeCacheEntry]
}

private struct SchemeCacheEntry: Codable {
    var schemes: [String]
    var signature: TimeInterval?
    var cachedAt: TimeInterval
}
