import Foundation

// MARK: - Package Description

/// The targets of a Swift package and the dependencies between them: the input of
/// `swift-modularity-cli package`.
///
/// The command plugin writes this as JSON from SwiftPM's plugin API. Run standalone, the CLI reads
/// it from `swift package dump-package` instead (see `PackageLoader`).
public struct PackageDescription: Sendable, Codable, Equatable {
    public struct Target: Sendable, Codable, Equatable {
        public var name: String
        /// SwiftPM's kind: `regular`, `executable`, `test`, `macro`, `plugin`, `system`, `binary`, ...
        public var kind: String
        /// The directory of the target's sources, if it has one.
        public var directory: String?
        /// The names of the targets of this package that the target depends on. Products of other
        /// packages are not listed.
        public var dependencies: [String]

        public init(name: String, kind: String, directory: String?, dependencies: [String]) {
            self.name = name
            self.kind = kind
            self.directory = directory
            self.dependencies = dependencies
        }

        /// Whether the target has Swift sources that can be analyzed.
        public var isSourceTarget: Bool {
            ["regular", "executable", "test", "macro", "snippet"].contains(kind) && directory != nil
        }

        public var isTest: Bool { kind == "test" }
    }

    public var name: String
    /// The package's root directory.
    public var directory: String
    public var targets: [Target]

    public init(name: String, directory: String, targets: [Target]) {
        self.name = name
        self.directory = directory
        self.targets = targets
    }

    /// The graph of the given targets (one node per target, in the given order) and the
    /// dependencies between them.
    public func targetGraph(of selected: [Target]) -> DependencyGraph {
        let names = selected.map(\.name)
        let included = Set(names)
        let dependencies = selected.flatMap { target in
            target.dependencies.filter { included.contains($0) }.map { (target.name, $0) }
        }
        return DependencyGraph(names: names, dependencies: dependencies)
    }
}

/// Reads a package's targets with `swift package dump-package`.
public enum PackageLoader {
    public struct LoadError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Runs `swift package dump-package` in `packageDirectory` and parses its output.
    public static func load(packageDirectory: String) throws -> PackageDescription {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "--package-path", packageDirectory, "dump-package"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LoadError(description: "`swift package dump-package` failed: \(message)")
        }
        return try parseDumpPackage(data, packageDirectory: packageDirectory)
    }

    /// Parses the JSON written by `swift package dump-package`.
    public static func parseDumpPackage(_ data: Data, packageDirectory: String) throws -> PackageDescription {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = root["targets"] as? [[String: Any]] else {
            throw LoadError(description: "Unexpected output from `swift package dump-package`")
        }
        let name = root["name"] as? String ?? URL(fileURLWithPath: packageDirectory).lastPathComponent
        let targetNames = Set(targets.compactMap { $0["name"] as? String })
        let directory = URL(fileURLWithPath: packageDirectory).standardizedFileURL

        let parsed = targets.compactMap { target -> PackageDescription.Target? in
            guard let name = target["name"] as? String else { return nil }
            let kind = target["type"] as? String ?? "regular"
            let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).compactMap { dependency -> String? in
                // {"byName": [name, condition]}, {"target": [name, condition]}; products of other
                // packages ({"product": [...]}) are outside the package.
                for key in ["byName", "target"] {
                    if let values = dependency[key] as? [Any], let dependencyName = values.first as? String,
                       targetNames.contains(dependencyName) {
                        return dependencyName
                    }
                }
                return nil
            }
            let sourceDirectory = resolveDirectory(of: name, kind: kind, path: target["path"] as? String, in: directory)
            return PackageDescription.Target(name: name, kind: kind, directory: sourceDirectory, dependencies: dependencies)
        }
        return PackageDescription(name: name, directory: directory.path, targets: parsed)
    }

    /// The target's custom path, or SwiftPM's default directories.
    static func resolveDirectory(of name: String, kind: String, path: String?, in package: URL) -> String? {
        if let path {
            return package.appendingPathComponent(path).standardizedFileURL.path
        }
        let parents = kind == "test" ? ["Tests"] : kind == "plugin" ? ["Plugins"] : ["Sources", "Source", "src", "srcs"]
        for parent in parents {
            let candidate = package.appendingPathComponent(parent).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate.path
            }
        }
        return nil
    }
}
