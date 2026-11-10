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
        /// The target's `sources:`, relative to `directory`: the files and directories that hold
        /// its sources. Nil for all of `directory`.
        public var sources: [String]?
        /// The target's `exclude:`, relative to `directory`: files and directories that are not
        /// compiled. Nil for none.
        public var exclude: [String]?

        public init(name: String, kind: String, directory: String?, dependencies: [String],
                    sources: [String]? = nil, exclude: [String]? = nil) {
            self.name = name
            self.kind = kind
            self.directory = directory
            self.dependencies = dependencies
            self.sources = sources
            self.exclude = exclude
        }

        /// The Swift files of the target: those under `directory` that SwiftPM compiles (within
        /// `sources`, outside `exclude`), less those matching `patterns`.
        public func swiftFiles(excluding patterns: [ExcludePattern] = []) throws -> [String] {
            guard let directory else { return [] }
            let files = try FileReader.findSwiftFiles(in: directory, excluding: patterns)
            let sources = sources.map { Set($0.map(Self.normalized)) }
            let exclude = Set((exclude ?? []).map(Self.normalized))
            guard sources != nil || !exclude.isEmpty else { return files }
            return files.filter { file in
                // FileReader spells the files under `directory` as given. A listed path covers
                // the file itself and, for a directory, everything under it: look up the file's
                // path and each directory above it (the plugin lists every file of the target).
                let relative = Self.normalized(String(file.dropFirst(directory.count)))
                var prefixes: Set<String> = ["", relative]
                for index in relative.indices where relative[index] == "/" {
                    prefixes.insert(String(relative[..<index]))
                }
                if let sources, sources.isDisjoint(with: prefixes) { return false }
                return exclude.isDisjoint(with: prefixes)
            }
        }

        /// A relative path without `.` and empty components (`./Main/` is `Main`; the directory
        /// itself is the empty string).
        private static func normalized(_ path: String) -> String {
            path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
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

        public init(description: String) {
            self.description = description
        }
    }

    /// Runs `swift package dump-package` in `packageDirectory` and parses its output.
    ///
    /// - Parameter disableSandbox: Compile the manifest outside SwiftPM's sandbox, which cannot be
    ///   started from inside another one (such as a command plugin's).
    public static func load(packageDirectory: String, disableSandbox: Bool = false) throws -> PackageDescription {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package"] + (disableSandbox ? ["--disable-sandbox"] : [])
            + ["--package-path", packageDirectory, "dump-package"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Read both pipes at once: a process that fills one while the other is read would block.
        let errorReader = PipeReader(errors.fileHandleForReading)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorReader.wait()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw LoadError(description: "`swift package dump-package` failed: "
                            + failureReason(errors: errorData, output: data, process: process))
        }
        return try parseDumpPackage(data, packageDirectory: packageDirectory)
    }

    /// What `swift package dump-package` wrote about its failure: its standard error and its
    /// standard output (where swiftly reports a `.swift-version` with no installed toolchain),
    /// else how it ended.
    static func failureReason(errors: Data, output: Data, process: Process) -> String {
        let texts = [errors, output]
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !texts.isEmpty { return texts.joined(separator: "\n") }
        switch process.terminationReason {
        case .uncaughtSignal:
            return "terminated by signal \(process.terminationStatus), with no output"
        default:
            return "exited with status \(process.terminationStatus), with no output"
        }
    }

    /// Reads a pipe to its end on another thread.
    private final class PipeReader: @unchecked Sendable {
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            Thread.detachNewThread { [self] in
                data = handle.readDataToEndOfFile()
                done.signal()
            }
        }

        func wait() -> Data {
            done.wait()
            return data
        }
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
            let exclude = target["exclude"] as? [String] ?? []
            return PackageDescription.Target(name: name, kind: kind, directory: sourceDirectory, dependencies: dependencies,
                                             sources: target["sources"] as? [String],
                                             exclude: exclude.isEmpty ? nil : exclude)
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
