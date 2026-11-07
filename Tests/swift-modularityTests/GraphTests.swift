import Testing
@testable import swift_modularity

@Suite struct GraphTests {
    /// Figure 3 of Baldwin, MacCormack and Rusnak (2014): A→B, A→C, B→D, C→E, E→F.
    static let paperExample = DependencyGraph(
        names: ["A", "B", "C", "D", "E", "F"],
        dependencies: [("A", "B"), ("A", "C"), ("B", "D"), ("C", "E"), ("E", "F")]
    )

    @Test func visibilityMatrixMatchesThePaper() {
        let graph = Self.paperExample
        let components = StronglyConnectedComponents(successors: graph.successors)
        let visibility = VisibilityMatrix(successors: graph.successors, components: components)
        // Figure 4.
        let expected = [
            [1, 1, 1, 1, 1, 1],
            [0, 1, 0, 1, 0, 0],
            [0, 0, 1, 0, 1, 1],
            [0, 0, 0, 1, 0, 0],
            [0, 0, 0, 0, 1, 1],
            [0, 0, 0, 0, 0, 1],
        ]
        for row in 0..<6 {
            for column in 0..<6 {
                #expect(visibility.contains(row: row, column: column) == (expected[row][column] == 1), "V[\(row)][\(column)]")
            }
        }
        // "element A has VFI equal to 1 ... and VFO equal to 6"
        #expect(visibility.fanIn[0] == 1)
        #expect(visibility.fanOut[0] == 6)
        #expect(visibility.fanOut == [6, 2, 3, 1, 2, 1])
        #expect(visibility.propagationCost == 15.0 / 36.0)
    }

    @Test func duplicateAndSelfEdgesAreMerged() {
        let graph = DependencyGraph(
            nodes: [.init(name: "a"), .init(name: "b")],
            edges: [
                .init(from: 0, to: 1, reference: .init(symbol: "B", line: 3, column: 1)),
                .init(from: 0, to: 1, reference: .init(symbol: "B", line: 9, column: 1), referenceCount: 2),
                .init(from: 1, to: 1),
            ]
        )
        #expect(graph.edges.count == 1)
        #expect(graph.edges[0].referenceCount == 3)
        #expect(graph.edges[0].reference?.line == 3)
        #expect(graph.successors == [[1], []])
    }

    @Test func stronglyConnectedComponentsInReverseTopologicalOrder() {
        // a → b → c → a, c → d, e alone.
        let graph = DependencyGraph(names: ["a", "b", "c", "d", "e"],
                                    dependencies: [("a", "b"), ("b", "c"), ("c", "a"), ("c", "d")])
        let components = StronglyConnectedComponents(successors: graph.successors)
        #expect(Set(components.components) == [[0, 1, 2], [3], [4]])
        let cycle = components.componentOfNode[0]
        let d = components.componentOfNode[3]
        #expect(d < cycle, "a component comes after the components it depends on")
        #expect(components.componentOfNode[1] == cycle && components.componentOfNode[2] == cycle)
    }

    @Test func deepChainsDoNotOverflowTheStack() {
        let count = 50_000
        let names = (0..<count).map(String.init)
        let dependencies = (0..<count).map { (names[$0], names[($0 + 1) % count]) }
        let graph = DependencyGraph(names: names, dependencies: dependencies)
        let components = StronglyConnectedComponents(successors: graph.successors)
        #expect(components.components.count == 1)
    }

    @Test(arguments: 0..<40)
    func visibilityMatchesWarshall(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let count = Int(random.next() % 40) + 1
        let density = Double(random.next() % 100) / 1000
        var edges: [DependencyGraph.Edge] = []
        for from in 0..<count {
            for to in 0..<count where from != to && Double(random.next() % 1000) / 1000 < density {
                edges.append(.init(from: from, to: to))
            }
        }
        let graph = DependencyGraph(nodes: (0..<count).map { .init(name: "n\($0)") }, edges: edges)

        // Reflexive transitive closure with Warshall's algorithm.
        var closure = Array(repeating: Array(repeating: false, count: count), count: count)
        for node in 0..<count { closure[node][node] = true }
        for edge in graph.edges { closure[edge.from][edge.to] = true }
        for k in 0..<count {
            for i in 0..<count where closure[i][k] {
                for j in 0..<count where closure[k][j] {
                    closure[i][j] = true
                }
            }
        }

        let components = StronglyConnectedComponents(successors: graph.successors)
        let visibility = VisibilityMatrix(successors: graph.successors, components: components)
        for i in 0..<count {
            for j in 0..<count {
                #expect(visibility.contains(row: i, column: j) == closure[i][j])
            }
            #expect(visibility.fanOut[i] == closure[i].filter { $0 }.count)
            #expect(visibility.fanIn[i] == (0..<count).filter { closure[$0][i] }.count)
        }
        // Members of a strongly connected component are mutually reachable, and only they are.
        for i in 0..<count {
            for j in 0..<count {
                let same = components.componentOfNode[i] == components.componentOfNode[j]
                #expect(same == (closure[i][j] && closure[j][i]))
            }
        }
    }

    @Test func emptyGraph() {
        let analysis = ModularityAnalysis(graph: DependencyGraph(names: [], dependencies: []))
        #expect(analysis.propagationCost == 0)
        #expect(analysis.architecture == .hierarchical)
        #expect(analysis.dsmOrder.isEmpty)
    }
}

/// A deterministic random number generator for reproducible tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
