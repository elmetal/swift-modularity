// MARK: - Architecture Analysis

/// The thresholds that classify an architecture, from Appendix A of Baldwin, MacCormack and
/// Rusnak (2014), "Hidden structure: Using network methods to map system architecture",
/// Research Policy 43(8). The defaults are the paper's: size 5%, sensitivity 1%, dominance 50%.
public struct ArchitectureThresholds: Sendable, Equatable, Codable {
    /// x: the share of the system above which the largest cyclic group is "large".
    public var size: Double
    /// y: the margin around `size` within which a system is "borderline".
    public var sensitivity: Double
    /// z: how much larger than the next largest cyclic group the largest must be to dominate.
    public var dominance: Double

    public static let paper = ArchitectureThresholds(size: 0.05, sensitivity: 0.01, dominance: 0.5)

    public init(size: Double, sensitivity: Double, dominance: Double) {
        self.size = size
        self.sensitivity = sensitivity
        self.dominance = dominance
    }

    /// Why the thresholds cannot classify a system, or nil when they can: x must be a share of
    /// the system (0 < x ≤ 1), y a margin smaller than x (0 ≤ y < x), and z not negative.
    public var problem: String? {
        if !size.isFinite || size <= 0 || size > 1 {
            return "The size threshold must be more than 0 and at most 1 (got \(size))."
        }
        if !sensitivity.isFinite || sensitivity < 0 || sensitivity >= size {
            return "The sensitivity threshold must be at least 0 and less than the size threshold \(size) (got \(sensitivity))."
        }
        if !dominance.isFinite || dominance < 0 {
            return "The dominance threshold must be 0 or more (got \(dominance))."
        }
        return nil
    }
}

/// The architecture of a system, by the size of its largest cyclic group.
public enum ArchitectureType: String, Sendable, Codable, CaseIterable {
    /// One cyclic group that is large relative to the system and to every other cyclic group.
    case corePeriphery = "core-periphery"
    /// Like core-periphery, but the largest cyclic group is close to the size threshold.
    case borderlineCorePeriphery = "borderline-core-periphery"
    /// Two or more similarly sized, large cyclic groups.
    case multiCore = "multi-core"
    /// Every cyclic group is small relative to the system.
    case hierarchical
}

/// How the elements were divided into groups.
public enum PartitionView: String, Sendable, Codable {
    /// By the VFI and VFO of the largest cyclic group (the Core). Used for core-periphery and
    /// borderline core-periphery systems.
    case corePeriphery = "core-periphery"
    /// By the median VFI and VFO. Used for multi-core and hierarchical systems.
    case median
}

/// The group of an element in the partition.
public enum ComponentGroup: String, Sendable, Codable, CaseIterable {
    /// Depended on at least as widely as the Core, depending on less than the Core: shared
    /// infrastructure.
    case shared
    /// A member of the largest cyclic group (core-periphery view).
    case core
    /// At or above both medians (median view). In the core-periphery view, an element outside
    /// the Core whose VFI and VFO both reach the Core's, which the paper's three non-Core groups
    /// do not cover (possible only for elements unrelated to the Core).
    case central
    /// Below the Core (or the medians) in both VFI and VFO.
    case peripheral
    /// Depending on at least as much as the Core, depended on by fewer: top-level code that uses
    /// the rest.
    case control

    /// The order of the groups in the reordered DSM: Shared, Core (or Central), Peripheral,
    /// Control.
    public static let dsmOrder: [ComponentGroup] = [.shared, .core, .central, .peripheral, .control]
}

/// The measures of Baldwin, MacCormack and Rusnak (2014) for one dependency graph: the visibility
/// matrix, propagation cost, cyclic groups, architecture type and the partition of the elements
/// into Shared, Core (or Central), Peripheral and Control groups.
///
/// Everything is computed exactly from the graph; nothing is sampled or approximated.
public struct ModularityAnalysis: Sendable {
    public let graph: DependencyGraph
    public let thresholds: ArchitectureThresholds
    public let components: StronglyConnectedComponents
    public let visibility: VisibilityMatrix
    /// Cyclic groups (strongly connected components with two or more elements), largest first,
    /// ties by their first member's name. The first, if any, is the largest cyclic group.
    public let cyclicGroups: [[Int]]
    public let architecture: ArchitectureType
    public let view: PartitionView
    /// The group of each element.
    public let groups: [ComponentGroup]
    /// The elements in the order of the reordered DSM (group order, then VFI descending, VFO
    /// ascending, name).
    public let dsmOrder: [Int]
    /// The median VFI and VFO over all elements.
    public let medianFanIn: Double
    public let medianFanOut: Double

    public init(graph: DependencyGraph, thresholds: ArchitectureThresholds = .paper) {
        let components = StronglyConnectedComponents(successors: graph.successors)
        let visibility = VisibilityMatrix(successors: graph.successors, components: components)
        let names = graph.nodes.map(\.name)
        let cyclicGroups = components.components
            .filter { $0.count >= 2 }
            .map { group in group.sorted { names[$0] < names[$1] } }
            .sorted { ($0.count, names[$1[0]]) > ($1.count, names[$0[0]]) }

        let architecture = Self.classify(
            largest: cyclicGroups.first?.count ?? 0,
            nextLargest: cyclicGroups.dropFirst().first?.count ?? 0,
            total: graph.count,
            thresholds: thresholds
        )
        let medianFanIn = Self.median(visibility.fanIn)
        let medianFanOut = Self.median(visibility.fanOut)

        let view: PartitionView
        var groups: [ComponentGroup]
        switch architecture {
        case .corePeriphery, .borderlineCorePeriphery:
            // Both types require a largest cyclic group of at least (x - y) of the system.
            let core = cyclicGroups[0]
            let coreFanIn = Double(visibility.fanIn[core[0]])
            let coreFanOut = Double(visibility.fanOut[core[0]])
            view = .corePeriphery
            groups = (0..<graph.count).map {
                Self.group(fanIn: visibility.fanIn[$0], fanOut: visibility.fanOut[$0],
                           fanInThreshold: coreFanIn, fanOutThreshold: coreFanOut, high: .central)
            }
            for member in core {
                groups[member] = .core
            }
        case .multiCore, .hierarchical:
            view = .median
            groups = (0..<graph.count).map {
                Self.group(fanIn: visibility.fanIn[$0], fanOut: visibility.fanOut[$0],
                           fanInThreshold: medianFanIn, fanOutThreshold: medianFanOut, high: .central)
            }
        }

        let groupRank = Dictionary(uniqueKeysWithValues: ComponentGroup.dsmOrder.enumerated().map { ($1, $0) })
        self.dsmOrder = (0..<graph.count).sorted { a, b in
            let keyA = (groupRank[groups[a]]!, -visibility.fanIn[a], visibility.fanOut[a])
            let keyB = (groupRank[groups[b]]!, -visibility.fanIn[b], visibility.fanOut[b])
            return keyA != keyB ? keyA < keyB : names[a] < names[b]
        }
        self.graph = graph
        self.thresholds = thresholds
        self.components = components
        self.visibility = visibility
        self.cyclicGroups = cyclicGroups
        self.cyclicGroupIndexByNode = Dictionary(uniqueKeysWithValues: cyclicGroups.enumerated().flatMap { index, group in
            group.map { ($0, index) }
        })
        self.architecture = architecture
        self.view = view
        self.groups = groups
        self.medianFanIn = medianFanIn
        self.medianFanOut = medianFanOut
    }

    /// The propagation cost of the graph (see `VisibilityMatrix.propagationCost`).
    public var propagationCost: Double { visibility.propagationCost }

    /// The number of elements in the largest cyclic group (0 if there is none).
    public var largestCyclicGroupSize: Int { cyclicGroups.first?.count ?? 0 }

    /// The share of the system in the largest cyclic group.
    public var largestCyclicGroupRatio: Double {
        graph.count == 0 ? 0 : Double(largestCyclicGroupSize) / Double(graph.count)
    }

    /// The index in `cyclicGroups` of each element's cyclic group, or nil.
    public func cyclicGroupIndex(of element: Int) -> Int? {
        cyclicGroupIndexByNode[element]
    }

    private let cyclicGroupIndexByNode: [Int: Int]

    /// Appendix A, step 7: with nC the size of the largest cyclic group, N the size of the system
    /// and n~C the size of the next largest,
    /// (a) nC ≥ (x − y)·N, (b) nC ≥ (1 + z)·n~C, (c) nC ≥ (x + y)·N.
    /// All three: core-periphery; (a) and (b): borderline; (a) only: multi-core; not (a):
    /// hierarchical.
    public static func classify(largest: Int, nextLargest: Int, total: Int, thresholds: ArchitectureThresholds) -> ArchitectureType {
        // A cyclic group has at least two elements; without one there is no Core.
        guard largest >= 2, total > 0 else { return .hierarchical }
        // Tolerance for decimal thresholds that are not exact in binary (0.05 - 0.01 > 0.04).
        let tolerance = 1e-9
        let size = Double(largest)
        let n = Double(total)
        guard size + tolerance >= (thresholds.size - thresholds.sensitivity) * n else { return .hierarchical }
        guard size + tolerance >= (1 + thresholds.dominance) * Double(nextLargest) else { return .multiCore }
        guard size + tolerance >= (thresholds.size + thresholds.sensitivity) * n else { return .borderlineCorePeriphery }
        return .corePeriphery
    }

    /// Steps 10 and 11 of Appendix A, for one element.
    static func group(fanIn: Int, fanOut: Int, fanInThreshold: Double, fanOutThreshold: Double, high: ComponentGroup) -> ComponentGroup {
        switch (Double(fanIn) >= fanInThreshold, Double(fanOut) >= fanOutThreshold) {
        case (true, false): return .shared
        case (true, true): return high
        case (false, false): return .peripheral
        case (false, true): return .control
        }
    }

    static func median(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? Double(sorted[middle - 1] + sorted[middle]) / 2
            : Double(sorted[middle])
    }
}
