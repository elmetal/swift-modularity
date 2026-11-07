import Foundation

// MARK: - Config File

/// Settings read from a `modularity.toml` file, or given on the command line (nil: not given).
///
/// The file is a small subset of TOML: top-level `key = value` lines, `#` comments, and values
/// that are strings, numbers, booleans or arrays of strings (which may span lines). Keys may use
/// `_` or `-`:
///
/// ```toml
/// exclude = ["**/Generated/**"]   # added to --exclude
/// include_tests = false           # --include-tests (package)
/// size_threshold = 0.05           # --size-threshold
/// sensitivity_threshold = 0.01    # --sensitivity-threshold
/// dominance_threshold = 0.5       # --dominance-threshold
/// limit = 10                      # --limit
/// ```
public struct ModularityConfig: Sendable, Equatable {
    public static let fileName = "modularity.toml"

    public var exclude: [String] = []
    public var includeTests: Bool?
    public var sizeThreshold: Double?
    public var sensitivityThreshold: Double?
    public var dominanceThreshold: Double?
    public var limit: Int?
    /// Keys the file sets that are not supported, for warnings.
    public var unknownKeys: [String] = []

    public init() {}

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    /// The nearest `modularity.toml` in `directory` or one of its parents.
    public static func find(from directory: String) -> String? {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        while true {
            let candidate = url.appendingPathComponent(fileName).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    public static func load(path: String) throws -> ModularityConfig {
        try parse(String(contentsOfFile: path, encoding: .utf8))
    }

    public static func parse(_ text: String) throws -> ModularityConfig {
        var config = ModularityConfig()
        var lines = text.components(separatedBy: .newlines)[...]
        var lineNumber = 0
        while let rawLine = lines.popFirst() {
            lineNumber += 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let equals = line.firstIndex(of: "=") else {
                throw ParseError(description: "line \(lineNumber): expected `key = value`")
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "_")
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // Arrays may span lines.
            if value.hasPrefix("[") {
                while !value.hasSuffix("]"), let next = lines.popFirst() {
                    lineNumber += 1
                    value += " " + stripComment(next).trimmingCharacters(in: .whitespaces)
                }
            }
            let context = "line \(lineNumber) (\(key))"
            switch key {
            case "exclude": config.exclude = try parseStrings(value, context)
            case "include_tests": config.includeTests = try parseBool(value, context)
            case "size_threshold": config.sizeThreshold = try parseDouble(value, context)
            case "sensitivity_threshold": config.sensitivityThreshold = try parseDouble(value, context)
            case "dominance_threshold": config.dominanceThreshold = try parseDouble(value, context)
            case "limit":
                guard let number = Int(value) else { throw ParseError(description: "\(context): expected an integer") }
                config.limit = number
            default: config.unknownKeys.append(key)
            }
        }
        return config
    }

    /// Values set here override `base`; `exclude` patterns are added to it.
    public func overriding(_ base: ModularityConfig) -> ModularityConfig {
        var result = base
        result.exclude = base.exclude + exclude
        result.includeTests = includeTests ?? base.includeTests
        result.sizeThreshold = sizeThreshold ?? base.sizeThreshold
        result.sensitivityThreshold = sensitivityThreshold ?? base.sensitivityThreshold
        result.dominanceThreshold = dominanceThreshold ?? base.dominanceThreshold
        result.limit = limit ?? base.limit
        result.unknownKeys = base.unknownKeys + unknownKeys
        return result
    }

    /// The architecture thresholds, the paper's for those not set.
    public var thresholds: ArchitectureThresholds {
        let paper = ArchitectureThresholds.paper
        return ArchitectureThresholds(size: sizeThreshold ?? paper.size,
                                      sensitivity: sensitivityThreshold ?? paper.sensitivity,
                                      dominance: dominanceThreshold ?? paper.dominance)
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        for (offset, character) in line.enumerated() {
            if character == "\"" { inString.toggle() }
            if character == "#", !inString { return String(line.prefix(offset)) }
        }
        return line
    }

    private static func parseBool(_ value: String, _ context: String) throws -> Bool {
        switch value {
        case "true": return true
        case "false": return false
        default: throw ParseError(description: "\(context): expected true or false")
        }
    }

    private static func parseDouble(_ value: String, _ context: String) throws -> Double {
        guard let number = Double(value) else { throw ParseError(description: "\(context): expected a number") }
        return number
    }

    private static func parseString(_ value: String, _ context: String) throws -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            throw ParseError(description: "\(context): expected a string in double quotes")
        }
        return String(value.dropFirst().dropLast())
    }

    private static func parseStrings(_ value: String, _ context: String) throws -> [String] {
        guard value.hasPrefix("["), value.hasSuffix("]") else {
            throw ParseError(description: "\(context): expected an array of strings")
        }
        return try value.dropFirst().dropLast()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { try parseString($0, context) }
    }
}
