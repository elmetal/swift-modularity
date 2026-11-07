import ArgumentParser
import Foundation
import swift_modularity

@main
struct SwiftModularityCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-modularity-cli",
        abstract: "Measure the dependency structure of Swift code: propagation cost, cyclic groups and core-periphery architecture.",
        discussion: """
        Metrics follow MacCormack, Rusnak and Baldwin (2006) and Baldwin, MacCormack and Rusnak \
        (2014), "Hidden structure: Using network methods to map system architecture".
        """,
        version: "0.0.1",
        subcommands: [FilesCommand.self, PackageCommand.self],
        defaultSubcommand: FilesCommand.self
    )
}
