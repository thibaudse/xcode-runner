import Foundation

/// Low-level terminal handling with ANSI escape codes
enum Terminal {
    // MARK: - Raw Mode

    private static var originalTermios: termios?

    static func enableRawMode() {
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw

        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME

        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    static func disableRawMode() {
        if var original = originalTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        }
    }

    // MARK: - Cursor Control

    static func hideCursor() {
        print("\u{001B}[?25l", terminator: "")
    }

    static func showCursor() {
        print("\u{001B}[?25h", terminator: "")
    }

    static func moveCursor(row: Int, col: Int) {
        print("\u{001B}[\(row);\(col)H", terminator: "")
    }

    static func moveUp(_ n: Int = 1) {
        print("\u{001B}[\(n)A", terminator: "")
    }

    static func moveDown(_ n: Int = 1) {
        print("\u{001B}[\(n)B", terminator: "")
    }

    static func moveToColumn(_ col: Int) {
        print("\u{001B}[\(col)G", terminator: "")
    }

    // MARK: - Screen Control

    static func clearScreen() {
        print("\u{001B}[2J", terminator: "")
        moveCursor(row: 1, col: 1)
    }

    static func clearLine() {
        print("\u{001B}[2K", terminator: "")
    }

    static func clearToEndOfLine() {
        print("\u{001B}[K", terminator: "")
    }

    static func clearToEndOfScreen() {
        print("\u{001B}[J", terminator: "")
    }

    // MARK: - Alternate Screen Buffer

    static func enterAlternateScreen() {
        print("\u{001B}[?1049h", terminator: "")
    }

    static func exitAlternateScreen() {
        print("\u{001B}[?1049l", terminator: "")
    }

    // MARK: - Terminal Size

    static var size: (width: Int, height: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return (Int(w.ws_col), Int(w.ws_row))
        }
        return (80, 24)
    }

    static var isInteractive: Bool {
        isatty(STDIN_FILENO) != 0
    }

    // MARK: - Input

    static func readKey() -> Key? {
        var buffer = [UInt8](repeating: 0, count: 3)
        let bytesRead = read(STDIN_FILENO, &buffer, 3)

        guard bytesRead > 0 else { return nil }

        if bytesRead == 1 {
            switch buffer[0] {
            case 0x1B: return .escape
            case 0x0D, 0x0A: return .enter
            case 0x7F: return .backspace
            case 0x09: return .tab
            case 0x03: return .ctrlC
            case 0x04: return .ctrlD
            default:
                if buffer[0] >= 32 && buffer[0] < 127 {
                    return .char(Character(UnicodeScalar(buffer[0])))
                }
            }
        } else if bytesRead == 3 && buffer[0] == 0x1B && buffer[1] == 0x5B {
            switch buffer[2] {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            default: break
            }
        }

        return nil
    }

    enum Key {
        case up, down, left, right
        case enter, escape, backspace, tab
        case ctrlC, ctrlD
        case char(Character)
    }

    // MARK: - Output

    static func flush() {
        fflush(stdout)
    }

    static func write(_ text: String) {
        print(text, terminator: "")
    }

    static func writeLine(_ text: String = "") {
        print(text)
    }
}

// MARK: - Styles

enum Style {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[2m"
    static let italic = "\u{001B}[3m"
    static let underline = "\u{001B}[4m"

    // Foreground colors
    static let black = "\u{001B}[30m"
    static let red = "\u{001B}[31m"
    static let green = "\u{001B}[32m"
    static let yellow = "\u{001B}[33m"
    static let blue = "\u{001B}[34m"
    static let magenta = "\u{001B}[35m"
    static let cyan = "\u{001B}[36m"
    static let white = "\u{001B}[37m"

    // Bright foreground colors
    static let brightBlack = "\u{001B}[90m"
    static let brightRed = "\u{001B}[91m"
    static let brightGreen = "\u{001B}[92m"
    static let brightYellow = "\u{001B}[93m"
    static let brightBlue = "\u{001B}[94m"
    static let brightMagenta = "\u{001B}[95m"
    static let brightCyan = "\u{001B}[96m"
    static let brightWhite = "\u{001B}[97m"

    // Background colors
    static let bgBlack = "\u{001B}[40m"
    static let bgRed = "\u{001B}[41m"
    static let bgGreen = "\u{001B}[42m"
    static let bgYellow = "\u{001B}[43m"
    static let bgBlue = "\u{001B}[44m"
    static let bgMagenta = "\u{001B}[45m"
    static let bgCyan = "\u{001B}[46m"
    static let bgWhite = "\u{001B}[47m"
}

extension String {
    func styled(_ styles: String...) -> String {
        styles.joined() + self + Style.reset
    }

    var bold: String { styled(Style.bold) }
    var dim: String { styled(Style.dim) }
    var italic: String { styled(Style.italic) }
    var underline: String { styled(Style.underline) }

    var red: String { styled(Style.red) }
    var green: String { styled(Style.green) }
    var yellow: String { styled(Style.yellow) }
    var blue: String { styled(Style.blue) }
    var magenta: String { styled(Style.magenta) }
    var cyan: String { styled(Style.cyan) }
    var white: String { styled(Style.white) }

    var brightBlack: String { styled(Style.brightBlack) }
    var brightRed: String { styled(Style.brightRed) }
    var brightGreen: String { styled(Style.brightGreen) }
    var brightYellow: String { styled(Style.brightYellow) }
    var brightBlue: String { styled(Style.brightBlue) }
    var brightCyan: String { styled(Style.brightCyan) }
}
