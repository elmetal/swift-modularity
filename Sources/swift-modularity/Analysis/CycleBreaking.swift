// MARK: - Dependencies That Split a Cyclic Group

/// A dependency between two members of a cyclic group whose removal splits the group.
public struct BreakingDependency: Sendable, Equatable {
    /// The dependency, with its first reference and number of references.
    public var edge: DependencyGraph.Edge
    /// The size of the cyclic group the dependency is in.
    public var groupSize: Int
    /// The sizes of the cyclic groups left among the group's members without the dependency,
    /// largest first (empty when no cycle is left).
    public var remainingGroupSizes: [Int]

    /// The size of the largest cyclic group left (0 when no cycle is left).
    public var largestRemaining: Int { remainingGroupSizes.first ?? 0 }

    /// How many members leave the largest group: `groupSize - largestRemaining`.
    public var reduction: Int { groupSize - largestRemaining }

    /// Members that are in no cyclic group any more.
    public var acyclicMembers: Int { groupSize - remainingGroupSizes.reduce(0, +) }
}

/// Finds the dependencies whose removal splits a cyclic group.
///
/// For each dependency between two members of a group that can split it (see
/// `spanningDependencies`), the strongly connected components of the group without that
/// dependency are computed exactly. Only dependencies that make the largest remaining group
/// smaller than the group are returned. Removing a dependency means removing every reference from
/// one file to the other; how many there are is `edge.referenceCount`.
///
/// The result is exact for the given graph. A graph built from syntax can miss dependencies (see
/// `FileDependencyGraphBuilder`), and a missing dependency can keep a group together that this
/// analysis splits.
public enum CycleBreaking {
    /// The dependencies that split `group`, the most effective first: the largest reduction, then
    /// the fewest references, then by file names.
    /// - Parameter group: A cyclic group of `graph` (as in `ModularityAnalysis.cyclicGroups`).
    public static func breakingDependencies(in graph: DependencyGraph, group: [Int]) -> [BreakingDependency] {
        guard group.count >= 2 else { return [] }
        let local = Dictionary(uniqueKeysWithValues: group.enumerated().map { ($1, $0) })
        // The group's own subgraph, in local indices.
        let successors = group.map { member in graph.successors[member].compactMap { local[$0] } }
        let candidates = spanningDependencies(successors)

        var result: [BreakingDependency] = []
        for (from, targets) in successors.enumerated() {
            for to in targets where candidates.contains(from * group.count + to) {
                let remaining = remainingGroupSizes(successors, removing: [(from, to)])
                guard (remaining.first ?? 0) < group.count,
                      let edge = graph.edge(from: group[from], to: group[to]) else { continue }
                result.append(BreakingDependency(edge: edge, groupSize: group.count, remainingGroupSizes: remaining))
            }
        }
        let names = graph.nodes.map(\.name)
        return result.sorted { a, b in
            if a.reduction != b.reduction { return a.reduction > b.reduction }
            if a.edge.referenceCount != b.edge.referenceCount { return a.edge.referenceCount < b.edge.referenceCount }
            return (names[a.edge.from], names[a.edge.to]) < (names[b.edge.from], names[b.edge.to])
        }
    }

    /// The sizes of the cyclic groups left in `group` of `graph` when all of `dependencies` are
    /// removed together, largest first. Dependencies that are not inside the group are ignored.
    public static func remainingGroupSizes(in graph: DependencyGraph, group: [Int], removing dependencies: [DependencyGraph.Edge]) -> [Int] {
        let local = Dictionary(uniqueKeysWithValues: group.enumerated().map { ($1, $0) })
        let successors = group.map { member in graph.successors[member].compactMap { local[$0] } }
        let removed = dependencies.compactMap { edge in local[edge.from].flatMap { from in local[edge.to].map { (from, $0) } } }
        return remainingGroupSizes(successors, removing: removed)
    }

    private static func remainingGroupSizes(_ successors: [[Int]], removing edges: [(Int, Int)]) -> [Int] {
        var pruned = successors
        for (from, to) in edges {
            pruned[from].removeAll { $0 == to }
        }
        return StronglyConnectedComponents(successors: pruned).components
            .map(\.count)
            .filter { $0 >= 2 }
            .sorted(by: >)
    }

    /// The only dependencies of a strongly connected graph whose removal can split it, as
    /// `from * count + to`: those of a spanning tree out of the first element and of one into it.
    /// Without any other dependency both trees are whole, so every element still reaches the first
    /// and is reached from it. At most 2 · (count − 1) dependencies, however many the graph has.
    private static func spanningDependencies(_ successors: [[Int]]) -> Set<Int> {
        let count = successors.count
        var predecessors = Array(repeating: [Int](), count: count)
        for (from, targets) in successors.enumerated() {
            for to in targets {
                predecessors[to].append(from)
            }
        }
        var result: Set<Int> = []
        // Breadth first from the first element: along the dependencies, then against them.
        for (neighbors, outward) in [(successors, true), (predecessors, false)] {
            var visited = Array(repeating: false, count: count)
            visited[0] = true
            var queue = [0]
            var next = 0
            while next < queue.count {
                let node = queue[next]
                next += 1
                for neighbor in neighbors[node] where !visited[neighbor] {
                    visited[neighbor] = true
                    queue.append(neighbor)
                    result.insert(outward ? node * count + neighbor : neighbor * count + node)
                }
            }
        }
        return result
    }
}
