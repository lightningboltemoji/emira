import CoreGraphics
import Foundation

/// A demo script: settings for the take, then the steps played and recorded, one command to a line.
/// The commands are in .agents/DEMO.md.
struct Tape {
    var name: String
    /// The take display's size in points; it is drawn at twice that in pixels.
    var display = CGSize(width: 1920, height: 1080)
    var seed: UInt64 = 1
    /// The stand-ins' colours, `RRGGBB` by name.
    var colors: [String: String] = [:]
    /// Played before the take starts recording, to set the scene.
    var setup: [Step] = []
    var steps: [Step] = []
}

struct Step {
    var line: Int
    var text: String
    var command: Command
}

enum Command {
    case sleep(Duration)
    case key([KeyCombo])
    /// Opens a stand-in of one of the tape's colours, by name, and waits for it to take focus on the
    /// take display.
    case open(String)
    case wait(Condition, timeout: Duration)
    case mark(String, Target)
}

enum Condition: CustomStringConvertible {
    /// The take display's workspace holds this many windows.
    case windows(Int)
    /// The take display shows this workspace.
    case workspace(String)
    /// Nothing emira draws is moving.
    case still

    var description: String {
        switch self {
        case .windows(let count): "\(count) window\(count == 1 ? "" : "s") on the take display"
        case .workspace(let name): "workspace \(name) on the take display"
        case .still: "emira to settle"
        }
    }
}

/// A rect on the take display, resolved when the step runs.
enum Target {
    case display
    /// The focused window.
    case focused
    /// The focused window's column.
    case column
    /// The windows on the take display's workspace, together.
    case workspace
    /// In display points from the top left.
    case rect(CGRect)
}

struct TapeError: Error, CustomStringConvertible {
    var line: Int
    var message: String
    var description: String { "line \(line): \(message)" }
}

extension Tape {
    init(contentsOf url: URL) throws {
        self.init(name: url.deletingPathExtension().lastPathComponent)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        var recordLine: Int?
        for (offset, raw) in lines.enumerated() {
            let number = offset + 1
            var words = try Self.split(raw, line: number)
            guard !words.isEmpty else { continue }
            let name = words.removeFirst().lowercased()
            var parser = Parser(words: words, line: number)
            if name == "record" {
                if let recordLine {
                    throw TapeError(line: number, message: "Record is already on line \(recordLine)")
                }
                recordLine = number
                setup = steps
                steps = []
            } else if try !applySetting(name, &parser) {
                let command = try parser.command(name)
                if case .open(let color) = command, colors[color] == nil {
                    throw TapeError(line: number, message: "no Color \(color) before this line")
                }
                steps.append(Step(line: number, text: raw.trimmingCharacters(in: .whitespaces), command: command))
            }
            try parser.end()
        }
        if recordLine == nil {
            throw TapeError(line: lines.count, message: "the tape never says Record")
        }
    }

    private mutating func applySetting(_ name: String, _ p: inout Parser) throws -> Bool {
        switch name {
        case "display":
            let size = try p.word().split(separator: "x").compactMap { Double($0) }
            guard size.count == 2 else { throw p.error("Display takes WIDTHxHEIGHT") }
            display = CGSize(width: size[0], height: size[1])
        case "seed": seed = UInt64(try p.number())
        case "color":
            let name = try p.word()
            let hex = try p.word()
            guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
                throw p.error("Color takes a name and RRGGBB, not \(hex)")
            }
            colors[name] = hex
        default: return false
        }
        return true
    }

    /// Splits a line into words: quoted strings are one word, and `#` starts a comment at the start of
    /// a line or after a space.
    static func split(_ line: String, line number: Int) throws -> [String] {
        var words: [String] = []
        var word = ""
        var inWord = false
        var quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\\", let next = chars.popFirst() {
                    word.append(next)
                } else if c == "\"" {
                    quoted = false
                } else {
                    word.append(c)
                }
            } else if c == "\"" {
                quoted = true
                inWord = true
            } else if c == " " || c == "\t" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else if c == "#" && !inWord {
                break
            } else {
                word.append(c)
                inWord = true
            }
        }
        if quoted { throw TapeError(line: number, message: "unterminated string") }
        if inWord { words.append(word) }
        return words
    }
}

private struct Parser {
    var words: [String]
    var line: Int
    var position = 0

    func error(_ message: String) -> TapeError {
        TapeError(line: line, message: message)
    }

    var atEnd: Bool { position == words.count }

    func peek() -> String? {
        atEnd ? nil : words[position]
    }

    mutating func word() throws -> String {
        guard let word = peek() else { throw error("expected more after \(words.joined(separator: " "))") }
        position += 1
        return word
    }

    mutating func rest() -> [String] {
        defer { position = words.count }
        return Array(words[position...])
    }

    mutating func number() throws -> Double {
        let word = try word()
        guard let value = Double(word) else { throw error("expected a number, not \(word)") }
        return value
    }

    /// `500ms`, `1.5s` or `2s`.
    mutating func duration() throws -> Duration {
        let word = try word()
        let (digits, scale): (Substring, Double) =
            word.hasSuffix("ms") ? (word.dropLast(2), 0.001) : word.hasSuffix("s") ? (word.dropLast(), 1) : ("", 0)
        guard let value = Double(digits) else { throw error("expected a duration like 500ms or 1.5s, not \(word)") }
        return .milliseconds(Int((value * scale * 1000).rounded()))
    }

    mutating func optionalDuration(_ fallback: Duration) throws -> Duration {
        guard let next = peek(), next.first?.isNumber == true else { return fallback }
        return try duration()
    }

    mutating func target() throws -> Target {
        let word = try word()
        switch word {
        case "display": return .display
        case "focused": return .focused
        case "column": return .column
        case "workspace": return .workspace
        default:
            let values = word.hasPrefix("@") ? word.dropFirst().split(separator: ",").compactMap { Double($0) } : []
            guard values.count == 4 else { throw error("expected display, focused, column, workspace or @X,Y,W,H, not \(word)") }
            return .rect(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        }
    }

    mutating func command(_ name: String) throws -> Command {
        switch name {
        case "sleep":
            return .sleep(try duration())
        case "key":
            let combos = try rest().map { try KeyCombo(parsing: $0, line: line) }
            guard !combos.isEmpty else { throw error("Key takes at least one key") }
            return .key(combos)
        case "open":
            return .open(try word())
        case "wait":
            let condition: Condition
            switch try word() {
            case "windows": condition = .windows(Int(try number()))
            case "workspace": condition = .workspace(try word())
            case "still": condition = .still
            case let other: throw error("can't wait for \(other): windows, workspace or still")
            }
            return .wait(condition, timeout: try optionalDuration(.seconds(10)))
        case "mark":
            let name = try word()
            return .mark(name, atEnd ? .display : try target())
        default:
            throw error("unknown command \(name)")
        }
    }

    func end() throws {
        if !atEnd { throw error("unexpected \(words[position...].joined(separator: " "))") }
    }
}
