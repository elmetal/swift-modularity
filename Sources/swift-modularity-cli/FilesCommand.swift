import ArgumentParser
import Foundation
import swift_modularity

/// `swift-modularity-cli files <paths>`: the file dependency structure of one module.
struct FilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files",
        abstract: "Analyze the dependencies between the Swift files of one module (the default command).",
        discussion: """
        Every Swift file under the given directories (and every given .swift file) is an element. \
        File A depends on file B when A refers to a type, top-level function, variable or macro \
        declared in B. All files are treated as one module.
        """
    )

    @Argument(help: "Directories and .swift files of the module.")
    var paths: [String]

    @Option(help: "The module name shown in the results (default: the last component of the first path).")
    var name: String?

    @OptionGroup var options: CommonOptions

    func validate() throws {
        guard !paths.isEmpty else { throw ValidationError("Give at least one directory or .swift file.") }
        for path in paths {
            do {
                try FileReader.validateInputPath(path)
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }
    }

    func run() async throws {
        let config = options.resolvedConfig()
        guard let module = try await Analyze.files(paths, name: name, currentDirectory: FileManager.default.currentDirectoryPath,
                                                   config: config) else { return }
        try options.emit(ModularityReport(modules: [module]), config: config)
    }
}
