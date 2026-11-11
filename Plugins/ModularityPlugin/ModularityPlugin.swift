import Foundation
import PackagePlugin

/// `swift package modularity [--target <name>]... [options]`
/// `swift package modularity diff [<revisions>] [options]`
/// `swift package modularity files <paths>... [options]`
///
/// Describes the package's targets and their dependencies as JSON (SwiftPM's plugin API knows
/// them without running `swift package dump-package`, which a plugin cannot do while SwiftPM holds
/// the package), then runs `swift-modularity-cli package --package-description <file>` with every
/// other argument, or `swift-modularity-cli diff --package-description <file>` for the working
/// tree's side of a diff, for example:
///
/// ```bash
/// swift package modularity --include-tests
/// swift package modularity --target App --format json
/// swift package modularity diff main...HEAD --format github
/// ```
@main
struct ModularityPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let targets = context.package.targets.map { target -> [String: Any] in
            let dependencies = target.dependencies.compactMap { dependency -> String? in
                if case .target(let dependencyTarget) = dependency { return dependencyTarget.name }
                return nil
            }
            var description: [String: Any] = [
                "name": target.name,
                "kind": Self.kind(of: target),
                "dependencies": dependencies,
            ]
            if let module = target as? SwiftSourceModuleTarget {
                let directory = module.directoryURL.path
                description["directory"] = directory
                // The files SwiftPM compiles, after the manifest's `sources:` and `exclude:`.
                // `sourceFiles` also lists the target's other files (resources, and files outside
                // `sources:` as unknown), so keep the sources only.
                description["sources"] = module.sourceFiles.compactMap { file -> String? in
                    let path = file.url.path
                    guard file.type == .source, file.url.pathExtension == "swift",
                          path.hasPrefix(directory + "/") else { return nil }
                    return String(path.dropFirst(directory.count + 1))
                }
            }
            return description
        }
        let package: [String: Any] = [
            "name": context.package.displayName,
            "directory": context.package.directoryURL.path,
            "targets": targets,
        ]
        let descriptionURL = context.pluginWorkDirectoryURL.appendingPathComponent("package-description.json")
        try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys]).write(to: descriptionURL)

        let tool = try context.tool(named: "swift-modularity-cli")
        let process = Process()
        process.executableURL = tool.url
        switch arguments.first {
        case "diff":
            var diffArguments = ["diff"]
            // The description is of this package as it is on disk; paths after -- or another
            // package directory are analyzed by the tool itself.
            if !arguments.contains("--") && !arguments.contains(where: { $0.hasPrefix("--package-path") }) {
                diffArguments += ["--package-description", descriptionURL.path]
            }
            process.arguments = diffArguments + arguments.dropFirst()
        case "files":
            // Directories of the package, relative to it, as one module: no description needed.
            process.arguments = arguments
        case "package":
            process.arguments = ["package", "--package-description", descriptionURL.path] + arguments.dropFirst()
        default:
            process.arguments = ["package", "--package-description", descriptionURL.path] + arguments
        }
        // Tells the tool that it runs in the plugin's sandbox (see `runsInPluginSandbox`).
        process.environment = ProcessInfo.processInfo.environment.merging(["SWIFT_MODULARITY_PLUGIN": "1"]) { $1 }
        // Run in the package directory, so that `modularity.toml` there is found and GitHub
        // annotation paths are relative to it.
        process.currentDirectoryURL = context.package.directoryURL
        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            // The tool has already explained the problem on stderr.
            throw PluginError("swift-modularity-cli exited with status \(process.terminationStatus)")
        }
    }

    static func kind(of target: Target) -> String {
        guard let module = target as? SwiftSourceModuleTarget else {
            return target is BinaryArtifactTarget ? "binary" : target is SystemLibraryTarget ? "system" : "other"
        }
        switch module.kind {
        case .generic: return "regular"
        case .executable: return "executable"
        case .test: return "test"
        case .macro: return "macro"
        case .snippet: return "snippet"
        @unknown default: return "regular"
        }
    }
}

struct PluginError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
