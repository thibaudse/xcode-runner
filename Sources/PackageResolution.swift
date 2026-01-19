import Foundation

struct PackageResolutionPolicy {
    static func shouldDisableAutomaticResolution(for project: XcodeProject, derivedDataPath: String) -> Bool {
        guard let signatureDate = PackageResolutionSignature.signatureDate(for: project) else { return false }
        guard let stateDate = workspaceStateDate(at: derivedDataPath) else { return false }
        return stateDate >= signatureDate
    }

    private static func workspaceStateDate(at derivedDataPath: String) -> Date? {
        let stateURL = URL(fileURLWithPath: derivedDataPath)
            .appendingPathComponent("SourcePackages")
            .appendingPathComponent("workspace-state.json")
        return modificationDate(at: stateURL)
    }

    fileprivate static func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

struct PackageResolutionSignature {
    static func signatureDate(for project: XcodeProject) -> Date? {
        switch project.type {
        case .workspace:
            return packageResolvedDates(in: project.path).max()
        case .project:
            let workspaceURL = project.path.appendingPathComponent("project.xcworkspace")
            let container = FileManager.default.fileExists(atPath: workspaceURL.path) ? workspaceURL : project.path
            return packageResolvedDates(in: container).max()
        }
    }

    private static func packageResolvedDates(in containerURL: URL) -> [Date] {
        var dates: [Date] = []
        let fm = FileManager.default

        let sharedResolved = containerURL
            .appendingPathComponent("xcshareddata")
            .appendingPathComponent("swiftpm")
            .appendingPathComponent("Package.resolved")
        if let date = PackageResolutionPolicy.modificationDate(at: sharedResolved) {
            dates.append(date)
        }

        let userData = containerURL.appendingPathComponent("xcuserdata")
        if fm.fileExists(atPath: userData.path) {
            if let enumerator = fm.enumerator(
                at: userData,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.lastPathComponent == "Package.resolved" else { continue }
                    if let date = PackageResolutionPolicy.modificationDate(at: fileURL) {
                        dates.append(date)
                    }
                }
            }
        }

        return dates
    }
}
