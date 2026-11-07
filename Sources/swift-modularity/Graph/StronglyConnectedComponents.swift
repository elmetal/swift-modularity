// MARK: - Strongly Connected Components

/// The strongly connected components of a directed graph, found with Tarjan's algorithm
/// (iterative, so deep graphs do not overflow the stack).
///
/// A component with two or more elements is a *cyclic group* in Baldwin, MacCormack and Rusnak
/// (2014): every member depends, directly or indirectly, on every other member.
public struct StronglyConnectedComponents: Sendable, Equatable {
    /// The components in reverse topological order: a component comes after every component it
    /// depends on. Members are sorted.
    public let components: [[Int]]
    /// The index in `components` of each element's component.
    public let componentOfNode: [Int]

    public init(successors: [[Int]]) {
        let count = successors.count
        var nextIndex = 0
        var indices = Array(repeating: -1, count: count)
        var lowLinks = Array(repeating: 0, count: count)
        var onStack = Array(repeating: false, count: count)
        var stack: [Int] = []
        var components: [[Int]] = []
        var componentOfNode = Array(repeating: -1, count: count)

        for root in 0..<count where indices[root] == -1 {
            // Each frame is a node and the position of the next successor to visit.
            var frames: [(node: Int, next: Int)] = []

            func open(_ node: Int) {
                indices[node] = nextIndex
                lowLinks[node] = nextIndex
                nextIndex += 1
                stack.append(node)
                onStack[node] = true
                frames.append((node, 0))
            }

            open(root)
            while let (node, next) = frames.last {
                if next < successors[node].count {
                    frames[frames.count - 1].next += 1
                    let successor = successors[node][next]
                    if indices[successor] == -1 {
                        open(successor)
                    } else if onStack[successor] {
                        lowLinks[node] = min(lowLinks[node], indices[successor])
                    }
                    continue
                }
                frames.removeLast()
                if let parent = frames.last {
                    lowLinks[parent.node] = min(lowLinks[parent.node], lowLinks[node])
                }
                if lowLinks[node] == indices[node] {
                    var component: [Int] = []
                    while true {
                        let member = stack.removeLast()
                        onStack[member] = false
                        componentOfNode[member] = components.count
                        component.append(member)
                        if member == node { break }
                    }
                    components.append(component.sorted())
                }
            }
        }
        self.components = components
        self.componentOfNode = componentOfNode
    }
}
