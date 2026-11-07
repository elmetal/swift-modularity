import Foundation

// MARK: - Git

/// The git commands that `diff` needs: resolving revisions and checking one out into a temporary
/// worktree, so that the user's working tree is never touched.
public struct Git: Sendable {
    public struct GitError: Error, CustomStringConvertible {
        public let description: String
    }

    /// A directory inside the repository.
    public var directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// Runs git with `arguments` and returns its standard output without the final newline.
    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        let process = Process()
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
        // Read both pipes before waiting, so that a full pipe cannot block git.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
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
    /// `main` or `master`.
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

    /// Checks out `commit` into a new temporary directory, outside the repository.
    public func addWorktree(at commit: String) throws -> Worktree {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("swift-modularity-\(UUID().uuidString)")
        try run(["worktree", "add", "--detach", "--quiet", parent.path, commit])
        return Worktree(git: self, path: parent.path)
    }

    /// A temporary checkout; `remove()` deletes it.
    public struct Worktree: Sendable {
        let git: Git
        public let path: String

        public func remove() {
            if (try? git.run(["worktree", "remove", "--force", path])) == nil {
                try? FileManager.default.removeItem(atPath: path)
                _ = try? git.run(["worktree", "prune"])
            }
        }
    }
}
