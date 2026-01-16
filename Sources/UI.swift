import Foundation

struct SelectionSection<T> {
    let title: String
    let items: [T]
}

/// UI Components for the TUI
enum UI {
    private struct SectionRow<T> {
        let isHeader: Bool
        let title: String
        let item: T?
    }

    private static let selectionMarker = "▸"
    private static let sectionMarker = "▌"

    // MARK: - Progress Bar

    static func progressBar(percentage: Double, width: Int = 40, label: String? = nil) -> String {
        let filled = Int(percentage / 100.0 * Double(width))
        let empty = width - filled

        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        let percentText = String(format: "%3.0f%%", percentage)

        if let label = label {
            return "\(label) [\(bar.cyan)] \(percentText)"
        }
        return "[\(bar.cyan)] \(percentText)"
    }

    // MARK: - Spinner

    struct Spinner {
        private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        private var frameIndex = 0

        mutating func next() -> String {
            let frame = Self.frames[frameIndex]
            frameIndex = (frameIndex + 1) % Self.frames.count
            return frame.cyan
        }
    }

    // MARK: - Selection List

    static func selectionList<T>(
        items: [T],
        selectedIndex: Int,
        displayName: (T) -> String,
        maxVisible: Int = 10
    ) -> String {
        var lines: [String] = []

        let startIndex: Int
        let endIndex: Int

        if items.count <= maxVisible {
            startIndex = 0
            endIndex = items.count
        } else {
            // Center the selection in the visible area
            let halfVisible = maxVisible / 2
            startIndex = max(0, min(selectedIndex - halfVisible, items.count - maxVisible))
            endIndex = min(items.count, startIndex + maxVisible)
        }

        // Show scroll indicator at top if needed
        if startIndex > 0 {
            lines.append("  ↑ \(startIndex) more...".dim)
        }

        for (index, item) in items.enumerated() where index >= startIndex && index < endIndex {
            let name = displayName(item)
            if index == selectedIndex {
                lines.append("  \(Style.brightCyan)\(selectionMarker)\(Style.reset) \(name.bold)")
            } else {
                lines.append("    \(name)")
            }
        }

        // Show scroll indicator at bottom if needed
        let remaining = items.count - endIndex
        if remaining > 0 {
            lines.append("  ↓ \(remaining) more...".dim)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Sectioned Selection List

    static func sectionedSelectionList<T>(
        sections: [SelectionSection<T>],
        selectedIndex: Int,
        displayName: (T) -> String,
        maxVisible: Int = 10
    ) -> String {
        var rows: [SectionRow<T>] = []
        var itemRowIndices: [Int] = []

        for section in sections where !section.items.isEmpty {
            rows.append(SectionRow(isHeader: true, title: section.title, item: nil))
            for item in section.items {
                rows.append(SectionRow(isHeader: false, title: "", item: item))
                itemRowIndices.append(rows.count - 1)
            }
        }

        guard !rows.isEmpty else { return "" }

        let selectionRowIndex: Int? = itemRowIndices.indices.contains(selectedIndex) ? itemRowIndices[selectedIndex] : nil

        let startIndex: Int
        let endIndex: Int

        if rows.count <= maxVisible {
            startIndex = 0
            endIndex = rows.count
        } else {
            let halfVisible = maxVisible / 2
            let anchor = selectionRowIndex ?? 0
            startIndex = max(0, min(anchor - halfVisible, rows.count - maxVisible))
            endIndex = min(rows.count, startIndex + maxVisible)
        }

        var lines: [String] = []

        if startIndex > 0 {
            lines.append("  ↑ \(startIndex) more...".dim)
        }

        for rowIndex in startIndex..<endIndex {
            let row = rows[rowIndex]
            if row.isHeader {
                lines.append(sectionHeader(row.title))
            } else if let item = row.item {
                let name = displayName(item)
                if let selectionRowIndex, rowIndex == selectionRowIndex {
                    lines.append("  \(Style.brightCyan)\(selectionMarker)\(Style.reset) \(name.bold)")
                } else {
                    lines.append("    \(name)")
                }
            }
        }

        let remaining = rows.count - endIndex
        if remaining > 0 {
            lines.append("  ↓ \(remaining) more...".dim)
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Box Drawing

    static func box(title: String, content: String, width: Int? = nil) -> String {
        let contentLines = content.components(separatedBy: "\n")
        let termWidth = width ?? Terminal.size.width
        let maxContentWidth = contentLines.map { stripAnsi($0).count }.max() ?? 0
        let boxWidth = min(max(maxContentWidth + 4, title.count + 6), termWidth - 4)

        var lines: [String] = []

        // Top border with title
        let titlePadded = " \(title) "
        let topBorderLength = boxWidth - 2 - titlePadded.count
        let leftBorder = topBorderLength / 2
        let rightBorder = topBorderLength - leftBorder
        lines.append("╭" + String(repeating: "─", count: leftBorder) + titlePadded.bold + String(repeating: "─", count: rightBorder) + "╮")

        // Content
        for line in contentLines {
            let stripped = stripAnsi(line)
            let padding = boxWidth - 2 - stripped.count
            lines.append("│ " + line + String(repeating: " ", count: max(0, padding - 1)) + "│")
        }

        // Bottom border
        lines.append("╰" + String(repeating: "─", count: boxWidth - 2) + "╯")

        return lines.joined(separator: "\n")
    }

    // MARK: - Status Line

    static func statusLine(icon: String, message: String, detail: String? = nil) -> String {
        var line = "\(icon) \(message)"
        if let detail = detail {
            line += " \(detail.dim)"
        }
        return line
    }

    // MARK: - Header

    static func header() -> String {
        let title = "Xcode Runner".bold.cyan
        let subtitle = "Build • Run • Ship".dim

        let termWidth = Terminal.size.width
        let rawTitle = stripAnsi(title)
        let rawSubtitle = stripAnsi(subtitle)
        let contentWidth = max(rawTitle.count, rawSubtitle.count) + 8
        let boxWidth = min(max(36, contentWidth), max(24, termWidth - 4))

        if boxWidth < 24 {
            return "  \(title)\n"
        }

        let top = "  ╭" + String(repeating: "─", count: boxWidth - 2) + "╮"
        let midTitle = "  │" + padCenter(title, width: boxWidth - 2) + "│"
        let midSubtitle = "  │" + padCenter(subtitle, width: boxWidth - 2) + "│"
        let bottom = "  ╰" + String(repeating: "─", count: boxWidth - 2) + "╯"

        return [top, midTitle, midSubtitle, bottom].joined(separator: "\n")
    }

    // MARK: - Help Line

    static func helpLine(_ text: String) -> String {
        return text.dim
    }

    // MARK: - Utilities

    private static func sectionHeader(_ title: String) -> String {
        let label = title.uppercased()
        return "  \(Style.brightCyan)\(sectionMarker)\(Style.reset) \(label.brightCyan)"
    }

    private static func padCenter(_ text: String, width: Int) -> String {
        let stripped = stripAnsi(text)
        let length = stripped.count
        if length >= width { return text }
        let padding = width - length
        let left = padding / 2
        let right = padding - left
        return String(repeating: " ", count: left) + text + String(repeating: " ", count: right)
    }

    private static func stripAnsi(_ text: String) -> String {
        let pattern = "\u{001B}\\[[0-9;]*m"
        return text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

// MARK: - Animated UI

actor AnimatedUI {
    private var isRunning = false
    private var spinner = UI.Spinner()
    private var message: String = ""
    private var detail: String?

    func start(message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
        self.isRunning = true

        Task {
            await runAnimation()
        }
    }

    func update(message: String, detail: String? = nil) {
        self.message = message
        self.detail = detail
    }

    func stop() {
        isRunning = false
    }

    private func runAnimation() async {
        while isRunning {
            Terminal.moveToColumn(1)
            Terminal.clearLine()

            let frame = spinner.next()
            var line = "\(frame) \(message)"
            if let detail = detail {
                line += " \(detail.dim)"
            }
            Terminal.write(line)
            Terminal.flush()

            try? await Task.sleep(nanoseconds: 80_000_000) // ~12.5 FPS
        }

        // Clear the spinner line
        Terminal.moveToColumn(1)
        Terminal.clearLine()
    }
}
