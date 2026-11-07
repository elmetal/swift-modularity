import Foundation
import PackagePlugin

/// `swift package modularity [--target <name>]... [options]`
///
/// Describes the package's targets and their dependencies as JSON (SwiftPM's plugin API knows
/// them without running `swift package dump-package`, which a plugin cannot do while SwiftPM holds
/// the package), then runs `swift-modularity-cli package --package-description <file>` with every
/// other argument, for example:
///
/// ```bash
/// swift package modularity --include-tests
/// swift package modularity --target App --format github --fail-on-cycles
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
            if target is SwiftSourceModuleTarget {
                description["directory"] = target.directoryURL.path
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
        process.arguments = ["package", "--package-description", descriptionURL.path] + arguments
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
