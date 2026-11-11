import Foundation

// MARK: - Git

/// The git commands that `diff` needs: resolving revisions and exporting one into a temporary
/// directory. Nothing is written to the repository, so this also works in the sandbox of the
/// command plugin, which may only read the package directory.
public struct Git: Sendable {
    public struct GitError: Error, CustomStringConvertible {
        public let description: String
    }

    /// A directory inside the repository.
    public var directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// Runs git with `arguments` (and `environment` over the current one) and returns its standard
    /// output without the final newline.
    @discardableResult
    public func run(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw GitError(description: "Could not run git: \(error.localizedDescription)")
        }
        // Read both pipes at once: git would block on a full pipe while only the other is read.
        let errorReader = PipeReader(errors.fileHandleForReading)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorReader.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(description: "`git \(arguments.joined(separator: " "))` failed: \(message)")
        }
        var text = String(decoding: data, as: UTF8.self)
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// The root of the working tree, with symbolic links resolved.
    public func topLevel() throws -> String {
        URL(fileURLWithPath: try run(["rev-parse", "--show-toplevel"])).resolvingSymlinksInPath().path
    }

    /// The full commit hash of a revision.
    public func commit(_ revision: String) throws -> String {
        do {
            return try run(["rev-parse", "--verify", "--quiet", "--end-of-options", revision + "^{commit}"])
        } catch {
            throw GitError(description: "'\(revision)' is not a commit in this repository.")
        }
    }

    public func mergeBase(_ first: String, _ second: String) throws -> String {
        do {
            return try run(["merge-base", "--end-of-options", first, second])
        } catch {
            throw GitError(description: "'\(first)' and '\(second)' have no merge base (in a shallow clone, fetch the full history).")
        }
    }

    /// The branch that a range without a base is compared with: `origin/HEAD`, else a local
    /// `main` or `master`, else `origin/main` or `origin/master`.
    public func defaultBranch() throws -> String {
        if let remote = try? run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]), !remote.isEmpty {
            return remote
        }
        for name in ["main", "master"] where (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"])) != nil {
            return name
        }
        for name in ["origin/main", "origin/master"] where (try? run(["rev-parse", "--verify", "--quiet", "refs/remotes/\(name)"])) != nil {
            return name
        }
        throw GitError(description: "Found no default branch (origin/HEAD, main or master); give the revisions to compare, such as `main...HEAD`.")
    }

    /// Writes the files of `commit` into a new temporary directory, outside the repository.
    ///
    /// The tree is read into a temporary index file and checked out from it, rather than with
    /// `git worktree add`, which records the worktree in `.git`.
    public func export(_ commit: String) throws -> Export {
        // From the root of the working tree: run in a subdirectory, `checkout-index --all` writes
        // only the files under it, and paths that lead out of it (`../Other`) would be missing.
        let repository = Git(directory: try topLevel())
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("swift-modularity-\(UUID().uuidString)")
        let export = Export(root: root.path)
        do {
            try FileManager.default.createDirectory(atPath: export.path, withIntermediateDirectories: true)
            let index = ["GIT_INDEX_FILE": root.appendingPathComponent("index").path]
            try repository.run(["read-tree", commit], environment: index)
            try repository.run(["checkout-index", "--all", "--prefix=\(export.path)/"], environment: index)
        } catch {
            export.remove()
            throw error
        }
        return export
    }

    /// The files of a commit in a temporary directory; `remove()` deletes them.
    public struct Export: Sendable {
        /// The directory holding the files and the temporary index.
        let root: String

        /// The directory of the files: the commit's root directory.
        public var path: String { root + "/tree" }

        public func remove() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }
}
