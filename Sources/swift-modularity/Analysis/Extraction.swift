// MARK: - Directories That Could Become Targets

/// A directory of a module, and whether its files could become a target of their own.
///
/// A set of files can be split off as a target without a dependency cycle between targets when
/// the dependencies cross its boundary in one direction only:
///
/// - **lower target**: none of its files depends on a file outside it, so the rest of the module
///   can depend on the new target (a library or a layer below);
/// - **upper target**: no file outside depends on its files, so the new target can depend on the
///   rest (a feature on top).
///
/// Directories are the candidates because they are how a codebase already groups its files. The
/// result is exact for the given graph; a graph built from syntax misses some dependencies, so a
/// directory reported as a lower or upper target can still have a dependency the tool cannot see.
public struct ExtractionCandidate: Sendable, Equatable {
    /// The directory, relative to the module (as in the node names), with a trailing `/`.
    public var directory: String
    /// The files under the directory, at any depth.
    public var files: [Int]
    /// Dependencies of the directory's files on other files of the module.
    public var outgoing: [DependencyGraph.Edge]
    /// Dependencies of other files of the module on the directory's files.
    public var incoming: [DependencyGraph.Edge]
    /// Files outside the directory that its files depend on, directly or indirectly: what would
    /// have to move with it to make a lower target.
    public var requiredFiles: [Int]
    /// The cyclic groups with members both inside and outside the directory, and what is left of
    /// each when the dependencies blocking it are removed together. Either direction leaves the
    /// same groups: with dependencies crossing the boundary one way only, no cycle crosses it, so
    /// each group splits into the cycles among its members inside and among its members outside.
    /// Empty when the directory is not blocked, or no cycle crosses its boundary.
    public var splitGroups: [GroupSplit]

    /// A cyclic group that a directory's boundary cuts through.
    public struct GroupSplit: Sendable, Equatable {
        /// The index of the group in `ModularityAnalysis.cyclicGroups`.
        public var group: Int
        public var groupSize: Int
        /// The sizes of the cyclic groups left among the group's members, largest first (empty
        /// when no cycle is left).
        public var remainingGroupSizes: [Int]
    }

    public var canBeLowerTarget: Bool { outgoing.isEmpty }
    public var canBeUpperTarget: Bool { incoming.isEmpty }
    public var isBlocked: Bool { !canBeLowerTarget && !canBeUpperTarget }
}

public enum Extraction {
    /// Every directory with at least two files that is not the whole module, ordered: directories
    /// that can be a target first (largest first), then blocked ones by the fewest dependencies
    /// blocking them in either direction.
    public static func directoryCandidates(in analysis: ModularityAnalysis) -> [ExtractionCandidate] {
        let graph = analysis.graph
        var filesByDirectory: [String: [Int]] = [:]
        for (index, node) in graph.nodes.enumerated() {
            let components = node.name.split(separator: "/").map(String.init)
            for depth in stride(from: 1, to: components.count, by: 1) {
                filesByDirectory[components.prefix(depth).joined(separator: "/") + "/", default: []].append(index)
            }
        }

        let candidates = filesByDirectory.compactMap { directory, files -> ExtractionCandidate? in
            guard files.count >= 2, files.count < graph.count else { return nil }
            let members = Set(files)
            let outgoing = graph.edges.filter { members.contains($0.from) && !members.contains($0.to) }
            let incoming = graph.edges.filter { !members.contains($0.from) && members.contains($0.to) }
            let required = (0..<graph.count).filter { other in
                !members.contains(other) && files.contains { analysis.visibility.contains(row: $0, column: other) }
            }
            // Only a blocked directory can have a cycle across its boundary.
            let splits = outgoing.isEmpty || incoming.isEmpty ? [] : analysis.cyclicGroups.enumerated().compactMap { index, group -> ExtractionCandidate.GroupSplit? in
                guard group.contains(where: members.contains), !group.allSatisfy(members.contains) else { return nil }
                let remaining = CycleBreaking.remainingGroupSizes(in: graph, group: group, removing: outgoing)
                return .init(group: index, groupSize: group.count, remainingGroupSizes: remaining)
            }
            return ExtractionCandidate(directory: directory, files: files.sorted(), outgoing: outgoing,
                                       incoming: incoming, requiredFiles: required, splitGroups: splits)
        }
        return candidates.sorted { a, b in
            if a.isBlocked != b.isBlocked { return !a.isBlocked }
            if a.isBlocked {
                let blockingA = min(a.outgoing.count, a.incoming.count)
                let blockingB = min(b.outgoing.count, b.incoming.count)
                if blockingA != blockingB { return blockingA < blockingB }
            }
            if a.files.count != b.files.count { return a.files.count > b.files.count }
            return a.directory < b.directory
        }
    }
}
