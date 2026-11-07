import Foundation

// MARK: - Revision Range

/// The two sides that `swift-modularity-cli diff` compares, written as in `git diff`.
///
/// - none: the merge base of the default branch and `HEAD`, compared with the working tree;
/// - `A...B`: the merge base of A and B, compared with B (a side left empty is `HEAD`);
/// - `A..B`: A compared with B (a side left empty is `HEAD`);
/// - `A`: A compared with the working tree.
public struct RevisionRange: Sendable, Equatable {
    public enum Base: Sendable, Equatable {
        /// The merge base of the repository's default branch and `HEAD`.
        case defaultBranchMergeBase
        /// The merge base of two revisions.
        case mergeBase(String, String)
        case revision(String)
    }

    public enum Head: Sendable, Equatable {
        /// The files as they are on disk, with uncommitted changes.
        case workingTree
        case revision(String)
    }

    public var base: Base
    public var head: Head

    public init(base: Base, head: Head) {
        self.base = base
        self.head = head
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Parses the `<revisions>` argument of `diff`; nil is the default range.
    public static func parse(_ text: String?) throws -> RevisionRange {
        guard let text else {
            return RevisionRange(base: .defaultBranchMergeBase, head: .workingTree)
        }
        func side(_ part: Substring) -> String { part.isEmpty ? "HEAD" : String(part) }
        if let range = text.range(of: "...") {
            let left = text[..<range.lowerBound], right = text[range.upperBound...]
            guard !right.contains("..") else { throw ParseError(description: "Invalid revision range '\(text)'.") }
            return RevisionRange(base: .mergeBase(side(left), side(right)), head: .revision(side(right)))
        }
        if let range = text.range(of: "..") {
            let left = text[..<range.lowerBound], right = text[range.upperBound...]
            guard !right.contains("..") else { throw ParseError(description: "Invalid revision range '\(text)'.") }
            return RevisionRange(base: .revision(side(left)), head: .revision(side(right)))
        }
        guard !text.isEmpty else { throw ParseError(description: "The revision is empty.") }
        return RevisionRange(base: .revision(text), head: .workingTree)
    }
}
