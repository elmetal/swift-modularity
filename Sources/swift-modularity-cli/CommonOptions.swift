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

    @Option(name: .long, help: "Skip files and directories matching a glob pattern (repeatable).")
    var exclude: [String] = []

    @Option(help: "List at most this many elements per group in text output (0: all; default 10).")
    var limit: Int?

    @Flag(help: "Print the reordered DSM in text output (modules of up to 80 elements).")
    var matrix = false

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
    func resolvedConfig() -> ModularityConfig {
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

    /// Writes the report.
    func emit(_ report: ModularityReport, config: ModularityConfig) throws {
        let text: String
        switch format {
        case .text:
            text = TextFormatter(limit: config.limit ?? 10, showMatrix: matrix).format(report)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            text = String(decoding: try encoder.encode(report), as: UTF8.self) + "\n"
        case .xcode:
            text = Self.terminated(DiagnosticFormatter.format(report, style: .xcode))
        case .github:
            text = Self.terminated(DiagnosticFormatter.format(report, style: .github, relativeTo: FileManager.default.currentDirectoryPath))
        }
        if let output {
            try text.write(toFile: output, atomically: true, encoding: .utf8)
        } else {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    private static func terminated(_ text: String) -> String {
        text.isEmpty ? "" : text + "\n"
    }
}

/// Writes a line to standard error, which is kept for diagnostics so that results can be piped.
func printDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Analyzes the Swift files under `paths` as one module.
func analyzeFiles(_ files: [String], moduleName: String, directory: String?, relativeTo base: String?, thresholds: ArchitectureThresholds) async -> ModuleReport {
    let result = await FileDependencyGraphBuilder().build(files: files, relativeTo: base)
    let analysis = ModularityAnalysis(graph: result.graph, thresholds: thresholds)
    return ModuleReport(name: moduleName, level: .file, directory: directory, analysis: analysis, unreadableFiles: result.unreadableFiles)
}
