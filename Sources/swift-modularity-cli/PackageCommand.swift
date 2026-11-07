import ArgumentParser
import Foundation
import swift_modularity

/// `swift-modularity-cli package`: the target graph of a Swift package and the file graph of each
/// target.
struct PackageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Analyze a Swift package: the dependencies between its targets, then between the files of each target.",
        discussion: """
        The targets are read with `swift package dump-package`, or from --package-description \
        (JSON written by the `swift package modularity` command plugin).
        """
    )

    @Option(help: "The package directory.")
    var packagePath: String = "."

    @Option(help: "Read the targets from this JSON file instead of running `swift package dump-package`.")
    var packageDescription: String?

    @Option(name: .customLong("target"), help: "Analyze only these targets (repeatable). Default: every Swift source target except tests.")
    var targets: [String] = []

    @Flag(inversion: .prefixedNo, help: "Include test targets when no --target is given.")
    var includeTests: Bool?

    @Flag(help: "Only analyze the target graph, not the files of each target.")
    var targetsOnly = false

    @OptionGroup var options: CommonOptions

    func run() async throws {
        let config = options.resolvedConfig()
        let package: PackageDescription
        do {
            if let packageDescription {
                let data = try Data(contentsOf: URL(fileURLWithPath: packageDescription))
                package = try JSONDecoder().decode(PackageDescription.self, from: data)
            } else {
                package = try PackageLoader.load(packageDirectory: packagePath)
            }
        } catch {
            printDiagnostic("error: \(error)")
            throw ExitCode(64)
        }

        let selected: [PackageDescription.Target]
        if targets.isEmpty {
            let includeTests = self.includeTests ?? config.includeTests ?? false
            selected = package.targets.filter { $0.isSourceTarget && (includeTests || !$0.isTest) }
        } else {
            selected = try targets.map { name in
                guard let target = package.targets.first(where: { $0.name == name }) else {
                    throw ValidationError("The package has no target named '\(name)'.")
                }
                guard target.isSourceTarget else {
                    throw ValidationError("'\(name)' is not a Swift source target.")
                }
                return target
            }
        }
        guard !selected.isEmpty else {
            printDiagnostic("error: the package has no Swift source targets to analyze")
            throw ExitCode(64)
        }

        var modules: [ModuleReport] = []
        let targetAnalysis = ModularityAnalysis(graph: package.targetGraph(of: selected), thresholds: config.thresholds)
        modules.append(ModuleReport(name: package.name, level: .target, directory: package.directory, analysis: targetAnalysis))

        if !targetsOnly {
            let exclude = config.exclude.map(ExcludePattern.init)
            for target in selected {
                guard let directory = target.directory else { continue }
                let files = try FileReader.findSwiftFiles(in: directory, excluding: exclude)
                // C and C++ targets have no Swift files.
                guard !files.isEmpty else { continue }
                let shownDirectory = FileDependencyGraphBuilder.displayPath(directory, relativeTo: package.directory)
                modules.append(await analyzeFiles(files, moduleName: target.name, directory: shownDirectory,
                                                  relativeTo: directory, thresholds: config.thresholds))
            }
        }
        try options.emit(ModularityReport(modules: modules), config: config)
    }
}
