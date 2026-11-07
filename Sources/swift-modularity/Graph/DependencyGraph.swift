// MARK: - Dependency Graph

/// A directed graph of elements (files or targets) in which an edge `i → j` means
/// "i depends on j": if j changes, i may have to change as well.
///
/// This is the first-order Design Structure Matrix (DSM) of Baldwin, MacCormack and Rusnak
/// (2014), stored as adjacency lists. Self-dependencies are not stored: the visibility matrix
/// always includes them (see `VisibilityMatrix`).
public struct DependencyGraph: Sendable, Equatable {
    /// An element of the system.
    public struct Node: Sendable, Hashable, Codable {
        /// The name shown in reports, unique within the graph.
        public var name: String
        /// The file or directory the element comes from, if any.
        public var path: String?

        public init(name: String, path: String? = nil) {
            self.name = name
            self.path = path
        }
    }

    /// Where a dependency was found: the first reference, in source order.
    public struct Reference: Sendable, Hashable, Codable {
        /// The name referenced, such as `Parser` or `Parser.Options`.
        public var symbol: String
        public var line: Int
        public var column: Int

        public init(symbol: String, line: Int, column: Int) {
            self.symbol = symbol
            self.line = line
            self.column = column
        }
    }

    /// A dependency of `from` on `to`.
    public struct Edge: Sendable, Hashable {
        public var from: Int
        public var to: Int
        /// The first reference that creates the dependency, when known.
        public var reference: Reference?
        /// How many references create the dependency (at least 1).
        public var referenceCount: Int

        public init(from: Int, to: Int, reference: Reference? = nil, referenceCount: Int = 1) {
            self.from = from
            self.to = to
            self.reference = reference
            self.referenceCount = referenceCount
        }
    }

    public let nodes: [Node]
    /// The elements each element depends on, sorted, without duplicates or itself.
    public let successors: [[Int]]
    /// Every edge, sorted by `from`, then `to`.
    public let edges: [Edge]

    /// Creates a graph. Edges to the element itself are dropped; duplicate edges are merged (the
    /// first reference is kept and the counts are added).
    /// - Precondition: Every edge refers to an index of `nodes`.
    public init(nodes: [Node], edges: [Edge]) {
        var merged: [Pair: Edge] = [:]
        for edge in edges {
            precondition(nodes.indices.contains(edge.from) && nodes.indices.contains(edge.to),
                         "Edge \(edge.from) → \(edge.to) refers to a missing node")
            guard edge.from != edge.to else { continue }
            let key = Pair(from: edge.from, to: edge.to)
            if var existing = merged[key] {
                existing.referenceCount += edge.referenceCount
                existing.reference = existing.reference ?? edge.reference
                merged[key] = existing
            } else {
                merged[key] = edge
            }
        }
        let sorted = merged.values.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        var successors = Array(repeating: [Int](), count: nodes.count)
        for edge in sorted {
            successors[edge.from].append(edge.to)
        }
        self.nodes = nodes
        self.edges = sorted
        self.successors = successors
        self.edgeIndex = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { (Pair(from: $1.from, to: $1.to), $0) })
    }

    /// Creates a graph from element names and `(dependent, dependency)` name pairs. Names in the
    /// pairs that are not in `names` are added after them.
    public init(names: [String], dependencies: [(String, String)]) {
        var nodes = names.map { Node(name: $0) }
        var index = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func indexOf(_ name: String) -> Int {
            if let existing = index[name] { return existing }
            nodes.append(Node(name: name))
            index[name] = nodes.count - 1
            return nodes.count - 1
        }
        let edges = dependencies.map { Edge(from: indexOf($0.0), to: indexOf($0.1)) }
        self.init(nodes: nodes, edges: edges)
    }

    /// The number of elements.
    public var count: Int { nodes.count }

    /// The edge from one element to another, if there is one.
    public func edge(from: Int, to: Int) -> Edge? {
        edgeIndex[Pair(from: from, to: to)].map { edges[$0] }
    }

    private struct Pair: Hashable, Sendable {
        var from: Int
        var to: Int
    }

    private let edgeIndex: [Pair: Int]

    public static func == (lhs: DependencyGraph, rhs: DependencyGraph) -> Bool {
        lhs.nodes == rhs.nodes && lhs.edges == rhs.edges
    }
}
