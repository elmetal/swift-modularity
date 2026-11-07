import Foundation

// MARK: - Exclude Patterns

/// A glob-style pattern that excludes files and directories from a scan.
///
/// A pattern is split at `/` into components. `*`, `?` and `[...]` match within one path
/// component (via `fnmatch`), and a `**` component matches any number of components, including
/// none. A pattern matches a path when it matches the path's last components, so `Tests` matches
/// every file or directory named `Tests`, `*.generated.swift` matches those files anywhere, and
/// `Generated/**` matches everything inside any `Generated` directory (and the directory itself).
/// Leading `./` and trailing `/` are ignored.
public struct ExcludePattern: Sendable, Hashable, CustomStringConvertible {
    /// The pattern as written.
    public let description: String
    private let components: [String]

    public init(_ pattern: String) {
        description = pattern
        var parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        while parts.first == "." {
            parts.removeFirst()
        }
        // Consecutive `**` are equivalent to one.
        components = parts.enumerated().compactMap { index, part in
            part == "**" && index > 0 && parts[index - 1] == "**" ? nil : part
        }
    }

    /// Whether the pattern matches a path, given as its components (relative to the scanned
    /// directory, or as written on the command line).
    public func matches(pathComponents path: [String]) -> Bool {
        guard !components.isEmpty else { return false }
        // Matching any trailing part of the path is matching the pattern with a leading `**`.
        let anchored = components.first == "**" ? components : ["**"] + components
        return Self.match(anchored[...], path.filter { $0 != "." && !$0.isEmpty }[...])
    }

    /// Whether the pattern matches a path given as a string.
    public func matches(path: String) -> Bool {
        matches(pathComponents: path.split(separator: "/").map(String.init))
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            let rest = pattern.dropFirst()
            // `**` takes 0...n components.
            var remaining = path
            while true {
                if match(rest, remaining) { return true }
                guard !remaining.isEmpty else { return false }
                remaining = remaining.dropFirst()
            }
        }
        guard let component = path.first, fnmatch(head, component, 0) == 0 else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }
}

extension Array where Element == ExcludePattern {
    /// Whether any pattern matches the path.
    func anyMatches(pathComponents: [String]) -> Bool {
        contains { $0.matches(pathComponents: pathComponents) }
    }
}
