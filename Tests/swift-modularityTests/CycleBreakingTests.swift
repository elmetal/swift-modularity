import Testing
@testable import swift_modularity

@Suite struct CycleBreakingTests {
    @Test func twoFileCycle() {
        let graph = DependencyGraph(names: ["a", "b"], dependencies: [("a", "b"), ("b", "a")])
        let result = CycleBreaking.breakingDependencies(in: graph, group: [0, 1])
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.remainingGroupSizes.isEmpty && $0.reduction == 2 && $0.acyclicMembers == 2 })
    }

    @Test func oneBackReferenceHoldsTwoCyclesTogether() {
        // {a, b, c} and {d, e} are cycles of their own, joined by c → d and e → a.
        let graph = DependencyGraph(
            names: ["a", "b", "c", "d", "e"],
            dependencies: [("a", "b"), ("b", "c"), ("c", "a"), ("c", "d"), ("d", "e"), ("e", "d"), ("e", "a")]
        )
        let result = CycleBreaking.breakingDependencies(in: graph, group: [0, 1, 2, 3, 4])
        let names = result.map { "\(graph.nodes[$0.edge.from].name)→\(graph.nodes[$0.edge.to].name)" }
        // Without a → b (or b → c) only d ⇄ e is left: 3 files leave. Without c → d or e → a, the
        // two cycles stay apart (3 + 2); without d → e, d is a dead end and only {a, b, c} is left.
        // c → a and e → d do not split it: a → b → c → d → e → a remains.
        #expect(names == ["a→b", "b→c", "c→d", "d→e", "e→a"])
        #expect(result.map(\.remainingGroupSizes) == [[2], [2], [3, 2], [3], [3, 2]])
        #expect(result.map(\.reduction) == [3, 3, 2, 2, 2])
    }

    @Test func noSingleDependencySplitsADenseGroup() {
        // Every pair depends on each other.
        let names = ["a", "b", "c"]
        let dependencies = names.flatMap { a in names.filter { $0 != a }.map { (a, $0) } }
        let graph = DependencyGraph(names: names, dependencies: dependencies)
        #expect(CycleBreaking.breakingDependencies(in: graph, group: [0, 1, 2]).isEmpty)
    }

    @Test func fewerReferencesFirstAmongEqualReductions() {
        let graph = DependencyGraph(nodes: [.init(name: "a"), .init(name: "b")], edges: [
            .init(from: 0, to: 1, referenceCount: 5),
            .init(from: 1, to: 0, referenceCount: 1),
        ])
        let result = CycleBreaking.breakingDependencies(in: graph, group: [0, 1])
        #expect(result.map(\.edge.referenceCount) == [1, 5])
    }

    @Test(arguments: 0..<30)
    func remainingGroupsMatchBruteForce(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let count = Int(random.next() % 12) + 2
        var edges: [DependencyGraph.Edge] = []
        for from in 0..<count {
            for to in 0..<count where from != to && random.next() % 100 < 30 {
                edges.append(.init(from: from, to: to))
            }
        }
        let graph = DependencyGraph(nodes: (0..<count).map { .init(name: "n\($0)") }, edges: edges)
        let analysis = ModularityAnalysis(graph: graph)
        for group in analysis.cyclicGroups {
            let found = Dictionary(uniqueKeysWithValues: CycleBreaking.breakingDependencies(in: graph, group: group)
                .map { ("\($0.edge.from)>\($0.edge.to)", $0.remainingGroupSizes) })
            let members = Set(group)
            for edge in graph.edges where members.contains(edge.from) && members.contains(edge.to) {
                // Brute force: mutual reachability within the group without the edge.
                let expected = Self.cyclicGroupSizes(graph: graph, members: group, without: (edge.from, edge.to))
                let key = "\(edge.from)>\(edge.to)"
                if (expected.first ?? 0) < group.count {
                    #expect(found[key] == expected, "edge \(key)")
                } else {
                    #expect(found[key] == nil, "edge \(key) does not split the group")
                }
            }
        }
    }

    /// Sizes of the groups of mutually reachable members (2 or more), by Warshall's algorithm.
    static func cyclicGroupSizes(graph: DependencyGraph, members: [Int], without removed: (Int, Int)) -> [Int] {
        let n = members.count
        var reach = Array(repeating: Array(repeating: false, count: n), count: n)
        for (i, a) in members.enumerated() {
            for (j, b) in members.enumerated() where graph.edge(from: a, to: b) != nil && !(a == removed.0 && b == removed.1) {
                reach[i][j] = true
            }
        }
        for k in 0..<n { for i in 0..<n where reach[i][k] { for j in 0..<n where reach[k][j] { reach[i][j] = true } } }
        var assigned = Array(repeating: false, count: n)
        var sizes: [Int] = []
        for i in 0..<n where !assigned[i] {
            let group = (0..<n).filter { $0 == i || (reach[i][$0] && reach[$0][i]) }
            group.forEach { assigned[$0] = true }
            if group.count >= 2 { sizes.append(group.count) }
        }
        return sizes.sorted(by: >)
    }
}
