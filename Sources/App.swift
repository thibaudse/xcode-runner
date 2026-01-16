import Foundation
import ArgumentParser

@main
struct XcodeRunnerApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-runner",
        abstract: "Build and run Xcode projects from the terminal",
        version: "1.0.0"
    )

    @Option(name: .shortAndLong, help: "Path to the project or workspace")
    var project: String?

    @Option(name: .shortAndLong, help: "The scheme to build")
    var scheme: String?

    @Option(name: .shortAndLong, help: "The device UDID to run on")
    var device: String?

    @Flag(name: .shortAndLong, help: "Skip device selection and use the first available simulator")
    var auto: Bool = false

    @Flag(name: .shortAndLong, help: "Show detailed build output")
    var verbose: Bool = false

    mutating func run() async throws {
        let app = XcodeRunner(
            projectPath: project,
            schemeName: scheme,
            deviceId: device,
            autoSelect: auto,
            verbose: verbose
        )

        try await app.run()
    }
}

// MARK: - Main Application

actor XcodeRunner {
    private let projectPath: String?
    private let schemeName: String?
    private let deviceId: String?
    private let autoSelect: Bool
    private let verbose: Bool

    private let deviceManager = DeviceManager.shared
    private let buildManager = BuildManager()
    private let appRunner = AppRunner()
    private let recentItems = RecentItemsManager.shared

    init(projectPath: String?, schemeName: String?, deviceId: String?, autoSelect: Bool, verbose: Bool) {
        self.projectPath = projectPath
        self.schemeName = schemeName
        self.deviceId = deviceId
        self.autoSelect = autoSelect
        self.verbose = verbose
    }

    func run() async throws {
        // Setup terminal
        setupTerminal()
        defer { cleanupTerminal() }

        do {
            // Show header
            printHeader()

            // Step 1: Find project
            let project = try await selectProject()
            print()

            // Step 2: Select scheme
            let scheme = try await selectScheme(from: project)
            print()

            // Step 3: Select device
            let device = try await selectDevice()
            print()

            // Step 4: Build
            let buildResult = try await performBuild(project: project, scheme: scheme, device: device)

            guard buildResult.success else {
                printError("Build failed. Please check the errors above.")
                return
            }

            guard let productPath = buildResult.productPath else {
                printError("Build succeeded but couldn't find the built app. Try running with --verbose to see the full output.")
                return
            }

            print()

            // Step 5: Run
            try await runApp(device: device, appPath: productPath)

            print()
            print("✅ ".green + "Done! Your app is running on \(device.name).".bold)
            print()

        } catch {
            printError(error.localizedDescription)
        }
    }

    // MARK: - Terminal Setup

    private func setupTerminal() {
        // Setup signal handlers
        signal(SIGINT) { _ in
            Terminal.showCursor()
            Terminal.disableRawMode()
            exit(0)
        }
    }

    private func cleanupTerminal() {
        Terminal.showCursor()
    }

    // MARK: - Header

    private func printHeader() {
        print()
        print(UI.header())
        print()
    }

    // MARK: - Project Selection

    private func selectProject() async throws -> XcodeProject {
        print("📁 ".bold + "Finding Xcode project...".bold)

        let manager = ProjectManager()
        let projects = try manager.discoverProjects()

        if projects.isEmpty {
            throw AppError.noProjectFound
        }

        if let path = projectPath {
            // Use specified project
            if let project = projects.first(where: { $0.path.path.contains(path) }) {
                print("   Using: \(project.displayName)".dim)
                return project
            }
            throw AppError.projectNotFound(path)
        }

        if projects.count == 1 {
            print("   Found: \(projects[0].displayName)".dim)
            return projects[0]
        }

        // Interactive selection
        return try interactiveSelect(
            title: "Select a project",
            items: projects,
            displayName: { $0.displayName }
        )
    }

    // MARK: - Scheme Selection

    private func selectScheme(from project: XcodeProject) async throws -> String {
        print("🎯 ".bold + "Selecting scheme...".bold)

        let schemes = project.schemes

        if schemes.isEmpty {
            throw AppError.noSchemesFound
        }

        if let name = schemeName {
            if schemes.contains(name) {
                print("   Using: \(name)".dim)
                await recentItems.addRecentScheme(name, forProject: project.path.path)
                return name
            }
            throw AppError.schemeNotFound(name)
        }

        if schemes.count == 1 {
            print("   Using: \(schemes[0])".dim)
            await recentItems.addRecentScheme(schemes[0], forProject: project.path.path)
            return schemes[0]
        }

        // Get recent schemes and build sectioned list
        let recentSchemes = await recentItems.getRecentSchemes(forProject: project.path.path)
        let sections = buildSectionedList(
            items: schemes,
            recentIds: recentSchemes,
            getId: { $0 }
        )

        // Interactive selection
        let selected = try interactiveSelectWithSections(
            title: "Select a scheme",
            sections: sections,
            displayName: { "📋 \($0)" }
        )

        await recentItems.addRecentScheme(selected, forProject: project.path.path)
        return selected
    }

    // MARK: - Device Selection

    private func selectDevice() async throws -> Device {
        print("📱 ".bold + "Finding devices...".bold)

        let devices = try await deviceManager.discoverAllDevices()

        if devices.isEmpty {
            throw AppError.noDevicesFound
        }

        if let id = deviceId {
            if let device = devices.first(where: { $0.id == id }) {
                print("   Using: \(device.displayName)".dim)
                await recentItems.addRecentDevice(device.id)
                return device
            }
            throw AppError.deviceNotFound(id)
        }

        if autoSelect {
            // Pick first booted simulator, or first available
            let device = devices.first(where: { $0.state == .booted }) ?? devices[0]
            print("   Auto-selected: \(device.displayName)".dim)
            await recentItems.addRecentDevice(device.id)
            return device
        }

        // Get recent devices and build sectioned list
        let recentDeviceIds = await recentItems.getRecentDevices()
        let sections = buildSectionedList(
            items: devices,
            recentIds: recentDeviceIds,
            getId: { $0.id }
        )

        // Interactive selection
        let selected = try interactiveSelectWithSections(
            title: "Select a device",
            sections: sections,
            displayName: { "\($0.displayName) \($0.stateDisplay)" }
        )

        await recentItems.addRecentDevice(selected.id)
        return selected
    }

    // MARK: - Interactive Selection

    private func interactiveSelect<T>(
        title: String,
        items: [T],
        displayName: @escaping (T) -> String
    ) throws -> T {
        var selectedIndex = 0
        var filterText = ""

        Terminal.enableRawMode()
        Terminal.hideCursor()
        defer {
            Terminal.disableRawMode()
            Terminal.showCursor()
        }

        // Helper to get filtered items
        func filteredItems() -> [T] {
            if filterText.isEmpty {
                return items
            }
            return items.filter { item in
                displayName(item).lowercased().contains(filterText.lowercased())
            }
        }

        // Calculate display area
        let maxVisible = min(items.count, 10)
        let totalLines = maxVisible + 4 // title + filter + items + help + extra

        // Print initial state
        printSelection(title: title, items: filteredItems(), selectedIndex: selectedIndex, filterText: filterText, displayName: displayName)

        while true {
            guard let key = Terminal.readKey() else { continue }

            let currentFiltered = filteredItems()

            switch key {
            case .up:
                if selectedIndex > 0 {
                    selectedIndex -= 1
                }
            case .down:
                if selectedIndex < currentFiltered.count - 1 {
                    selectedIndex += 1
                }
            case .enter:
                guard !currentFiltered.isEmpty else { continue }
                // Move cursor down past the selection UI
                Terminal.write("\n")
                print("   Selected: \(displayName(currentFiltered[selectedIndex]))".dim)
                return currentFiltered[selectedIndex]
            case .ctrlC, .escape:
                if !filterText.isEmpty {
                    // Clear filter first
                    filterText = ""
                    selectedIndex = 0
                } else {
                    throw AppError.cancelled
                }
            case .backspace:
                if !filterText.isEmpty {
                    filterText.removeLast()
                    selectedIndex = 0
                }
            case .char(let c):
                // Add character to filter
                filterText.append(c)
                selectedIndex = 0
            default:
                continue
            }

            // Move cursor up and redraw
            Terminal.moveUp(totalLines)
            printSelection(title: title, items: filteredItems(), selectedIndex: selectedIndex, filterText: filterText, displayName: displayName)
        }
    }

    private func interactiveSelectWithSections<T>(
        title: String,
        sections: [SelectionSection<T>],
        displayName: @escaping (T) -> String
    ) throws -> T {
        var selectedIndex = 0
        var filterText = ""
        var lastRenderedLines = 0

        Terminal.enableRawMode()
        Terminal.hideCursor()
        defer {
            Terminal.disableRawMode()
            Terminal.showCursor()
        }

        func filteredSections() -> [SelectionSection<T>] {
            guard !filterText.isEmpty else { return sections }
            let query = filterText.lowercased()
            return sections.compactMap { section in
                let filteredItems = section.items.filter { displayName($0).lowercased().contains(query) }
                return filteredItems.isEmpty ? nil : SelectionSection(title: section.title, items: filteredItems)
            }
        }

        func currentItems(from sections: [SelectionSection<T>]) -> [T] {
            sections.flatMap { $0.items }
        }

        func redraw() {
            if lastRenderedLines > 0 {
                Terminal.moveUp(lastRenderedLines)
                Terminal.moveToColumn(1)
                Terminal.clearToEndOfScreen()
            }

            let currentSections = filteredSections()
            let items = currentItems(from: currentSections)
            if selectedIndex >= items.count {
                selectedIndex = max(0, items.count - 1)
            }

            lastRenderedLines = printSelectionWithSections(
                title: title,
                sections: currentSections,
                selectedIndex: selectedIndex,
                filterText: filterText,
                displayName: displayName
            )
        }

        redraw()

        while true {
            guard let key = Terminal.readKey() else { continue }

            let currentSections = filteredSections()
            let items = currentItems(from: currentSections)

            switch key {
            case .up:
                if selectedIndex > 0 {
                    selectedIndex -= 1
                }
            case .down:
                if selectedIndex < items.count - 1 {
                    selectedIndex += 1
                }
            case .enter:
                guard !items.isEmpty else { continue }
                Terminal.write("\n")
                print("   Selected: \(displayName(items[selectedIndex]))".dim)
                return items[selectedIndex]
            case .ctrlC, .escape:
                if !filterText.isEmpty {
                    filterText = ""
                    selectedIndex = 0
                } else {
                    throw AppError.cancelled
                }
            case .backspace:
                if !filterText.isEmpty {
                    filterText.removeLast()
                    selectedIndex = 0
                }
            case .char(let c):
                filterText.append(c)
                selectedIndex = 0
            default:
                continue
            }

            redraw()
        }
    }

    private func printSelectionWithSections<T>(
        title: String,
        sections: [SelectionSection<T>],
        selectedIndex: Int,
        filterText: String,
        displayName: (T) -> String
    ) -> Int {
        print()
        print("   \(title):".bold)

        if filterText.isEmpty {
            print(UI.helpLine("   ⌕ Type to filter"))
        } else {
            print("   ⌕ \(filterText.cyan)".bold)
        }

        let itemCount = sections.reduce(0) { $0 + $1.items.count }
        var listLines = 0

        if itemCount == 0 {
            print("   No matches found".dim)
            listLines = 1
        } else {
            let list = UI.sectionedSelectionList(
                sections: sections,
                selectedIndex: selectedIndex,
                displayName: displayName
            )
            if list.isEmpty {
                print("   No matches found".dim)
                listLines = 1
            } else {
                print(list)
                listLines = list.components(separatedBy: "\n").count
            }
        }

        print()
        print(UI.helpLine("   ⌕ filter • ↑/↓ navigate • Enter select • Esc clear/cancel"))
        Terminal.flush()

        return listLines + 5
    }

    private func buildSectionedList<T, ID: Hashable>(
        items: [T],
        recentIds: [ID],
        getId: (T) -> ID
    ) -> [SelectionSection<T>] {
        guard !items.isEmpty else { return [] }

        var recentItems: [T] = []
        var seenIds: Set<ID> = []

        let itemsById = Dictionary(grouping: items, by: getId)
        for id in recentIds {
            if let item = itemsById[id]?.first, !seenIds.contains(id) {
                recentItems.append(item)
                seenIds.insert(id)
            }
        }

        var remaining: [T] = []
        for item in items {
            let id = getId(item)
            if !seenIds.contains(id) {
                remaining.append(item)
            }
        }

        var sections: [SelectionSection<T>] = []
        if !recentItems.isEmpty {
            sections.append(SelectionSection(title: "Recent", items: recentItems))
        }
        if !remaining.isEmpty {
            sections.append(SelectionSection(title: "All", items: remaining))
        }

        return sections
    }

    private func printSelection<T>(
        title: String,
        items: [T],
        selectedIndex: Int,
        filterText: String,
        displayName: (T) -> String
    ) {
        print()
        print("   \(title):".bold)

        // Show filter input
        if filterText.isEmpty {
            print(UI.helpLine("   ⌕ Type to filter"))
        } else {
            print("   ⌕ \(filterText.cyan)".bold)
        }

        if items.isEmpty {
            print("   No matches found".dim)
            // Pad to keep consistent height
            for _ in 0..<8 {
                print()
            }
        } else {
            print(UI.selectionList(items: items, selectedIndex: selectedIndex, displayName: displayName))
        }
        print()
        print(UI.helpLine("   ⌕ filter • ↑/↓ navigate • Enter select • Esc clear/cancel"))
        Terminal.flush()
    }

    // MARK: - Build

    private func performBuild(project: XcodeProject, scheme: String, device: Device) async throws -> BuildManager.BuildResult {
        print("🔨 ".bold + "Building \(scheme)...".bold)
        print()

        let config = BuildManager.BuildConfiguration(
            project: project,
            scheme: scheme,
            device: device,
            verbose: verbose
        )

        var lastPhase: BuildProgress.Phase?
        var progressLineCount = 0
        let isVerbose = verbose

        let result = try await buildManager.build(config: config) { progress in
            // Skip progress updates in verbose mode (raw output is shown instead)
            guard !isVerbose else { return }

            // Only update if phase changed or significant progress
            if progress.phase != lastPhase {
                lastPhase = progress.phase

                // Clear previous progress line
                if progressLineCount > 0 {
                    Terminal.moveUp(1)
                    Terminal.clearLine()
                }

                // Print new status
                let statusLine = "   \(progress.phase.icon) \(progress.message)"
                print(statusLine)
                progressLineCount = 1

                Terminal.flush()
            }
        }

        // Final build status
        if !isVerbose && progressLineCount > 0 {
            Terminal.moveUp(1)
            Terminal.clearLine()
        }

        if result.success {
            print("   ✅ Build succeeded in \(String(format: "%.1f", result.duration))s".green)
        } else {
            print("   ❌ Build failed".red)
            for error in result.errors.prefix(5) {
                print("      \(error)".red)
            }
        }

        if !result.warnings.isEmpty {
            print("   ⚠️  \(result.warnings.count) warning(s)".yellow)
        }

        return result
    }

    // MARK: - Run

    private func runApp(device: Device, appPath: String) async throws {
        print("🚀 ".bold + "Running app...".bold)

        guard let bundleId = AppRunner.extractBundleId(from: appPath) else {
            throw AppError.bundleIdNotFound
        }

        let progressHandler: (AppRunner.RunProgress) -> Void = { progress in
            print("   \(progress.icon) \(progress.message)")
        }

        switch device.type {
        case .simulator:
            try await appRunner.runOnSimulator(
                device: device,
                appPath: appPath,
                bundleId: bundleId,
                progress: progressHandler
            )
        case .physical:
            try await appRunner.runOnPhysicalDevice(
                device: device,
                appPath: appPath,
                bundleId: bundleId,
                progress: progressHandler
            )
        }
    }

    // MARK: - Error Handling

    private func printError(_ message: String) {
        print()
        print("❌ ".red + "Error: ".red.bold + message)
        print()
    }
}

// MARK: - Errors

enum AppError: LocalizedError {
    case noProjectFound
    case projectNotFound(String)
    case noSchemesFound
    case schemeNotFound(String)
    case noDevicesFound
    case deviceNotFound(String)
    case bundleIdNotFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noProjectFound:
            return "No Xcode project or workspace found in current directory"
        case .projectNotFound(let path):
            return "Project not found: \(path)"
        case .noSchemesFound:
            return "No schemes found in the project"
        case .schemeNotFound(let name):
            return "Scheme not found: \(name)"
        case .noDevicesFound:
            return "No devices found. Make sure Xcode is installed and simulators are available."
        case .deviceNotFound(let id):
            return "Device not found: \(id)"
        case .bundleIdNotFound:
            return "Could not extract bundle identifier from the built app"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
