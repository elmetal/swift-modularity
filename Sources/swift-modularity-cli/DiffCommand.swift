import ArgumentParser
import Foundation
import swift_modularity

/// `swift-modularity-cli diff [<revisions>] [-- <paths>...]`: how the dependency structure changed
/// between two revisions of a git repository.
struct DiffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare the dependency structure of two revisions: new and grown cyclic groups, propagation cost, architecture.",
        discussion: """
        Both sides are analyzed now, with this version of the tool and the current modularity.toml, \
        so no earlier report needs to be kept. A revision other than the working tree is exported \
        into a temporary directory; nothing in the repository is written.

        Revisions, as in `git diff` (an empty side of A...B or A..B is HEAD):
          (none)  merge base of the default branch and HEAD → working tree
          A...B   merge base of A and B → B
          A..B    A → B
          A       A → working tree
        The default branch is origin/HEAD, else main or master.

        Without paths, the package in --package-path is analyzed as `package` does. After --, \
        directories and .swift files are analyzed as one module, as `files` does. Paths are relative \
        to the current directory, which stands for the same directory in each revision.
        """
    )

    @Argument(help: "The revisions to compare (see above).")
    var revisions: String?

    @Argument(parsing: .postTerminator, help: "Directories and .swift files of one module, after --.")
    var paths: [String] = []

    @Option(help: "The module name shown for the paths after -- (default: the last component of the first path).")
    var name: String?

    @OptionGroup var targetOptions: TargetOptions

    @Option(help: .hidden)
    var packageDescription: String?

    @Option(name: [.short, .long], help: "Output format: text, json, or xcode / github (a note at each new dependency that closes or grows a cyclic group).")
    var format: OutputFormat = .text

    @Option(name: [.short, .long], help: "Write the results to this file instead of standard output.")
    var output: String?

    @OptionGroup var analysis: AnalysisOptions

    func validate() throws {
        do {
            _ = try RevisionRange.parse(revisions)
        } catch {
            throw ValidationError("\(error)")
        }
        if !paths.isEmpty && (!targetOptions.targets.isEmpty || targetOptions.targetsOnly || targetOptions.includeTests != nil || targetOptions.packagePath != ".") {
            throw ValidationError("Package options do not apply to paths given after --.")
        }
        if packageDescription != nil && (!paths.isEmpty || targetOptions.packagePath != ".") {
            throw ValidationError("--package-description describes the package in the current directory.")
        }
        if paths.isEmpty && name != nil {
            throw ValidationError("--name applies to paths given after --.")
        }
    }

    func run() async throws {
        let config = try analysis.resolvedConfig()
        let range = try RevisionRange.parse(revisions)
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path

        let diff: ModularityDiff
        do {
            let git = Git(directory: currentDirectory)
            let topLevel = try git.topLevel()
            // The current directory, relative to the root of the working tree.
            let relative = currentDirectory == topLevel ? "" : String(currentDirectory.dropFirst(topLevel.count + 1))

            let baseSide: ModularityDiff.Side
            switch range.base {
            case .defaultBranchMergeBase:
                let branch = try git.defaultBranch()
                baseSide = .init(name: "the merge base of \(branch) and HEAD", commit: try git.mergeBase(branch, "HEAD"))
            case let .mergeBase(first, second):
                baseSide = .init(name: "the merge base of \(first) and \(second)", commit: try git.mergeBase(first, second))
            case let .revision(revision):
                baseSide = .init(name: revision, commit: try git.commit(revision))
            }
            let headSide: ModularityDiff.Side
            switch range.head {
            case .workingTree: headSide = .init(name: "the working tree", commit: nil)
            case let .revision(revision): headSide = .init(name: revision, commit: try git.commit(revision))
            }

            let baseReport = try await analyze(baseSide, git: git, topLevel: topLevel, relative: relative, config: config)
            let headReport = try await analyze(headSide, git: git, topLevel: topLevel, relative: relative, config: config)
            if baseReport.modules.isEmpty && headReport.modules.isEmpty {
                printDiagnostic("error: none of \(paths.joined(separator: ", ")) exists in \(baseSide.name) or \(headSide.name)")
                throw ExitCode(64)
            }
            diff = ModularityDiff(base: baseReport, head: headReport, baseSide: baseSide, headSide: headSide)
        } catch let error as Git.GitError {
            printDiagnostic("error: \(error)")
            throw ExitCode(64)
        } catch let error as PackageLoader.LoadError {
            printDiagnostic("error: \(error)")
            throw ExitCode(64)
        }

        let text: String
        switch format {
        case .text:
            text = DiffTextFormatter(limit: config.limit ?? 10).format(diff) + "\n"
        case .json:
            text = try encodeJSON(diff)
        case .xcode:
            text = terminated(DiagnosticFormatter.format(diff, style: .xcode))
        case .github:
            text = terminated(DiagnosticFormatter.format(diff, style: .github, relativeTo: currentDirectory))
        }
        try write(text, to: output)
    }

    /// Analyzes one side, in a temporary export unless it is the working tree. Paths in the report
    /// are rewritten to the working tree's, so that both sides name files the same way.
    func analyze(_ side: ModularityDiff.Side, git: Git, topLevel: String, relative: String,
                 config: ModularityConfig) async throws -> ModularityReport {
        guard let commit = side.commit else {
            return try await analyze(root: topLevel, relative: relative, config: config, side: side)
        }
        let export = try git.export(commit)
        defer { export.remove() }
        let report = try await analyze(root: export.path, relative: relative, config: config, side: side)
        return Self.relocate(report, from: export.path, to: topLevel)
    }

    private func analyze(root: String, relative: String, config: ModularityConfig, side: ModularityDiff.Side) async throws -> ModularityReport {
        let directory = relative.isEmpty ? root : root + "/" + relative
        if !paths.isEmpty {
            let module = try await Analyze.files(paths, name: name, currentDirectory: directory, config: config, skipMissing: true)
            return ModularityReport(modules: module.map { [$0] } ?? [])
        }
        let package: PackageDescription
        if side.commit == nil, let packageDescription {
            // From the command plugin: SwiftPM holds the package, so `swift package dump-package`
            // would wait for it.
            let data = try Data(contentsOf: URL(fileURLWithPath: packageDescription))
            package = try JSONDecoder().decode(PackageDescription.self, from: data)
        } else {
            let packageDirectory = URL(fileURLWithPath: targetOptions.packagePath, relativeTo: URL(fileURLWithPath: directory))
                .standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: packageDirectory + "/Package.swift") else {
                throw PackageLoader.LoadError(description: "\(side.name) has no Package.swift in \(targetOptions.packagePath)")
            }
            // In the plugin's sandbox, SwiftPM cannot start the sandbox it compiles manifests in.
            let inPluginSandbox = ProcessInfo.processInfo.environment[Self.pluginEnvironmentKey] != nil
            package = try PackageLoader.load(packageDirectory: packageDirectory, disableSandbox: inPluginSandbox)
        }
        return try await Analyze.package(package, options: targetOptions, config: config, skipMissingTargets: true)
    }

    /// Set by the command plugin (see `ModularityPlugin`).
    static let pluginEnvironmentKey = "SWIFT_MODULARITY_PLUGIN"

    /// Replaces the `from` prefix of the paths in `report` with `to`.
    static func relocate(_ report: ModularityReport, from: String, to: String) -> ModularityReport {
        func move(_ path: String?) -> String? {
            guard let path else { return nil }
            if path == from { return to }
            return path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
        }
        var report = report
        for index in report.modules.indices {
            report.modules[index].directory = move(report.modules[index].directory)
            for element in report.modules[index].elements.indices {
                report.modules[index].elements[element].path = move(report.modules[index].elements[element].path)
            }
        }
        return report
    }
}
