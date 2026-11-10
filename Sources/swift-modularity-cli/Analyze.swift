import ArgumentParser
import Foundation
import swift_modularity

/// The analyses behind `files`, `package` and both sides of `diff`.
enum Analyze {
    /// Analyzes the Swift files under `paths` as one module.
    ///
    /// - Parameters:
    ///   - currentDirectory: The directory that relative paths are resolved against.
    ///   - skipMissing: Ignore paths that do not exist (in `diff`, a directory added since the
    ///     base); nil when none exists.
    static func files(_ paths: [String], name: String?, currentDirectory: String, config: ModularityConfig,
                      skipMissing: Bool = false) async throws -> ModuleReport? {
        // `isDirectory`: in `diff`, a current directory that the revision does not have would be
        // taken for a file, and the paths resolved against its parent.
        let current = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        let resolved = paths.map { URL(fileURLWithPath: $0, relativeTo: current).standardizedFileURL.path }
        let existing = skipMissing ? resolved.filter { FileManager.default.fileExists(atPath: $0) } : resolved
        guard let first = resolved.first, !existing.isEmpty else { return nil }

        let files = try FileReader.findSwiftFiles(in: existing, excluding: config.exclude.map(ExcludePattern.init))
        // Name files relative to the directory given, or to the current directory.
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory)
        let base = resolved.count == 1 && isDirectory.boolValue ? first : current.standardizedFileURL.path
        let moduleName = name ?? URL(fileURLWithPath: first).lastPathComponent
        return await module(files, name: moduleName, directory: paths.joined(separator: ", "),
                            relativeTo: base, thresholds: config.thresholds)
    }

    /// Analyzes the target graph of a package, then the files of each selected target.
    ///
    /// - Parameter skipMissingTargets: Leave out targets named with `--target` that the package
    ///   does not have (in `diff`, a target added since the base).
    static func package(_ package: PackageDescription, options: TargetOptions, config: ModularityConfig,
                        skipMissingTargets: Bool = false) async throws -> ModularityReport {
        let selected: [PackageDescription.Target]
        if options.targets.isEmpty {
            let includeTests = options.includeTests ?? config.includeTests ?? false
            selected = package.targets.filter { $0.isSourceTarget && (includeTests || !$0.isTest) }
        } else {
            selected = try options.targets.compactMap { name in
                guard let target = package.targets.first(where: { $0.name == name }) else {
                    if skipMissingTargets { return nil }
                    throw ValidationError("The package has no target named '\(name)'.")
                }
                guard target.isSourceTarget else {
                    throw ValidationError("'\(name)' is not a Swift source target.")
                }
                return target
            }
        }
        if selected.isEmpty && !skipMissingTargets {
            printDiagnostic("error: the package has no Swift source targets to analyze")
            throw ExitCode(64)
        }

        var modules: [ModuleReport] = []
        let targetAnalysis = ModularityAnalysis(graph: package.targetGraph(of: selected), thresholds: config.thresholds)
        modules.append(ModuleReport(name: package.name, level: .target, directory: package.directory, analysis: targetAnalysis))

        if !options.targetsOnly {
            let exclude = config.exclude.map(ExcludePattern.init)
            for target in selected {
                guard let directory = target.directory else { continue }
                let files = try target.swiftFiles(excluding: exclude)
                // C and C++ targets have no Swift files.
                guard !files.isEmpty else { continue }
                let shownDirectory = FileDependencyGraphBuilder.displayPath(directory, relativeTo: package.directory)
                modules.append(await module(files, name: target.name, directory: shownDirectory,
                                            relativeTo: directory, thresholds: config.thresholds))
            }
        }
        return ModularityReport(modules: modules)
    }

    static func module(_ files: [String], name: String, directory: String?, relativeTo base: String?,
                       thresholds: ArchitectureThresholds) async -> ModuleReport {
        let result = await FileDependencyGraphBuilder().build(files: files, relativeTo: base)
        let analysis = ModularityAnalysis(graph: result.graph, thresholds: thresholds)
        return ModuleReport(name: name, level: .file, directory: directory, analysis: analysis, unreadableFiles: result.unreadableFiles)
    }
}
