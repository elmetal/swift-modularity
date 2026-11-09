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

    @Option(help: "Read the targets from this JSON file instead of running `swift package dump-package`.")
    var packageDescription: String?

    @OptionGroup var targetOptions: TargetOptions

    @OptionGroup var options: CommonOptions

    func run() async throws {
        let config = try options.resolvedConfig()
        let package: PackageDescription
        do {
            if let packageDescription {
                let data = try Data(contentsOf: URL(fileURLWithPath: packageDescription))
                package = try JSONDecoder().decode(PackageDescription.self, from: data)
            } else {
                package = try PackageLoader.load(packageDirectory: targetOptions.packagePath)
            }
        } catch {
            printDiagnostic("error: \(error)")
            throw ExitCode(64)
        }

        try options.emit(try await Analyze.package(package, options: targetOptions, config: config), config: config)
    }
}
