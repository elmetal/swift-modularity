// MARK: - Visibility Matrix

/// The visibility matrix V of a dependency graph: `V[i][j] = 1` when element i depends on
/// element j directly or indirectly, including `V[i][i] = 1` (a path of length zero, "a change to
/// an element will always affect itself").
///
/// V is the reflexive transitive closure of the first-order matrix, as defined by MacCormack,
/// Rusnak and Baldwin (2006) and Baldwin, MacCormack and Rusnak (2014). It is computed exactly:
/// every member of a strongly connected component has the same row, so each component's row is
/// the union of its members and the rows of the components it depends on, taken in reverse
/// topological order. Rows are bit sets, so the time is O(c · (n + e) / 64) for c components,
/// n elements and e edges.
public struct VisibilityMatrix: Sendable {
    /// The number of elements.
    public let count: Int
    /// VFI (Visibility Fan-In) of each element: the number of elements that depend on it directly
    /// or indirectly, including itself (the column sum of V).
    public let fanIn: [Int]
    /// VFO (Visibility Fan-Out) of each element: the number of elements it depends on directly or
    /// indirectly, including itself (the row sum of V).
    public let fanOut: [Int]

    private let rows: [BitSet]
    private let componentOfNode: [Int]

    public init(successors: [[Int]], components: StronglyConnectedComponents) {
        let count = successors.count
        var rows: [BitSet] = []
        rows.reserveCapacity(components.components.count)
        // Marks the components already merged into the row being built.
        var mergedInto = Array(repeating: -1, count: components.components.count)
        for (index, members) in components.components.enumerated() {
            var row = BitSet(count: count)
            for member in members {
                row.insert(member)
            }
            for member in members {
                for successor in successors[member] {
                    let target = components.componentOfNode[successor]
                    guard target != index, mergedInto[target] != index else { continue }
                    // Reverse topological order: `target` was built before `index`.
                    mergedInto[target] = index
                    row.formUnion(rows[target])
                }
            }
            rows.append(row)
        }

        var fanIn = Array(repeating: 0, count: count)
        for (index, members) in components.components.enumerated() {
            rows[index].forEach { fanIn[$0] += members.count }
        }
        self.count = count
        self.rows = rows
        self.componentOfNode = components.componentOfNode
        self.fanIn = fanIn
        self.fanOut = (0..<count).map { rows[components.componentOfNode[$0]].count }
    }

    /// Whether element `i` depends on element `j` directly or indirectly (or `i == j`).
    public func contains(row i: Int, column j: Int) -> Bool {
        rows[componentOfNode[i]].contains(j)
    }

    /// Propagation cost: the density of V, `Σ VFO / n²`, "the fraction of the system that could
    /// potentially be affected when a change is made to a randomly selected component"
    /// (MacCormack et al., 2006). 0 for an empty graph.
    public var propagationCost: Double {
        guard count > 0 else { return 0 }
        let total = fanOut.reduce(0, +)
        return Double(total) / (Double(count) * Double(count))
    }
}

/// A fixed-size set of small integers.
struct BitSet: Sendable, Hashable {
    private var words: [UInt64]

    init(count: Int) {
        words = Array(repeating: 0, count: (count + 63) / 64)
    }

    mutating func insert(_ value: Int) {
        words[value >> 6] |= 1 << UInt64(value & 63)
    }

    func contains(_ value: Int) -> Bool {
        words[value >> 6] & (1 << UInt64(value & 63)) != 0
    }

    mutating func formUnion(_ other: BitSet) {
        for index in words.indices {
            words[index] |= other.words[index]
        }
    }

    var count: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    func forEach(_ body: (Int) -> Void) {
        for (index, word) in words.enumerated() {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                body(index << 6 | bit)
                remaining &= remaining - 1
            }
        }
    }
}
