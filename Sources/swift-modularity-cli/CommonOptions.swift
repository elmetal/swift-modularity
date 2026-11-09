import ArgumentParser
import Foundation
import swift_modularity

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case text, json, xcode, github
}

/// Options shared by `files` and `package`.
struct CommonOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Output format: text, json, or xcode / github (a note at the dependency that best splits each cyclic group).")
    var format: OutputFormat = .text

    @Option(name: [.short, .long], help: "Write the results to this file instead of standard output.")
    var output: String?

    @Flag(help: "Print the reordered DSM in text output (modules of up to 80 elements).")
    var matrix = false

    @OptionGroup var analysis: AnalysisOptions

    func resolvedConfig() throws -> ModularityConfig { try analysis.resolvedConfig() }

    /// Writes the report.
    func emit(_ report: ModularityReport, config: ModularityConfig) throws {
        let text: String
        switch format {
        case .text:
            text = TextFormatter(limit: config.limit ?? 10, showMatrix: matrix).format(report)
        case .json:
            text = try encodeJSON(report)
        case .xcode:
            text = terminated(DiagnosticFormatter.format(report, style: .xcode))
        case .github:
            text = terminated(DiagnosticFormatter.format(report, style: .github, relativeTo: FileManager.default.currentDirectoryPath))
        }
        try write(text, to: output)
    }
}

/// Options that set what is analyzed and how it is classified, shared by every command.
struct AnalysisOptions: ParsableArguments {
    @Option(name: .long, help: "Skip files and directories matching a glob pattern (repeatable).")
    var exclude: [String] = []

    @Option(help: "List at most this many elements per list in text output (0: all; default 10).")
    var limit: Int?

    @Option(help: "Size threshold x of the architecture classification (default 0.05).")
    var sizeThreshold: Double?

    @Option(help: "Sensitivity threshold y of the architecture classification (default 0.01).")
    var sensitivityThreshold: Double?

    @Option(help: "Dominance threshold z of the architecture classification (default 0.5).")
    var dominanceThreshold: Double?

    @Flag(help: "Do not read modularity.toml.")
    var noConfig = false

    func validate() throws {
        if let limit, limit < 0 {
            throw ValidationError("--limit must be 0 or more.")
        }
    }

    /// The command-line options over the nearest `modularity.toml`.
    ///
    /// - Throws: A `ValidationError` when the resulting thresholds or limit are out of range.
    func resolvedConfig() throws -> ModularityConfig {
        let config = mergedConfig()
        if let problem = config.thresholds.problem {
            throw ValidationError(problem)
        }
        if let limit = config.limit, limit < 0 {
            throw ValidationError("The limit must be 0 or more (got \(limit)).")
        }
        return config
    }

    private func mergedConfig() -> ModularityConfig {
        var commandLine = ModularityConfig()
        commandLine.exclude = exclude
        commandLine.sizeThreshold = sizeThreshold
        commandLine.sensitivityThreshold = sensitivityThreshold
        commandLine.dominanceThreshold = dominanceThreshold
        commandLine.limit = limit

        var file = ModularityConfig()
        if !noConfig, let path = ModularityConfig.find(from: FileManager.default.currentDirectoryPath) {
            do {
                file = try ModularityConfig.load(path: path)
                for key in file.unknownKeys {
                    printDiagnostic("warning: \(path): unknown key '\(key)' is ignored")
                }
            } catch {
                printDiagnostic("warning: \(path) is ignored: \(error)")
            }
        }
        return commandLine.overriding(file)
    }
}

/// Options that choose the targets of a package, shared by `package` and `diff`.
struct TargetOptions: ParsableArguments {
    @Option(help: "The package directory.")
    var packagePath: String = "."

    @Option(name: .customLong("target"), help: "Analyze only these targets (repeatable). Default: every Swift source target except tests.")
    var targets: [String] = []

    @Flag(inversion: .prefixedNo, help: "Include test targets when no --target is given.")
    var includeTests: Bool?

    @Flag(help: "Only analyze the target graph, not the files of each target.")
    var targetsOnly = false
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
}

func terminated(_ text: String) -> String {
    text.isEmpty ? "" : text + "\n"
}

/// Writes `text` to the file at `path`, or to standard output.
func write(_ text: String, to path: String?) throws {
    if let path {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            printDiagnostic("error: could not write \(path): \(error.localizedDescription)")
            if ProcessInfo.processInfo.environment[DiffCommand.pluginEnvironmentKey] != nil {
                // SwiftPM's sandbox lets a command plugin write only in its own directory.
                printDiagnostic("note: the command plugin cannot write into the package; redirect the output instead (swift package modularity > report.txt), or run swift package --disable-sandbox modularity")
            }
            throw ExitCode.failure
        }
    } else {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

/// Writes a line to standard error, which is kept for diagnostics so that results can be piped.
func printDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
