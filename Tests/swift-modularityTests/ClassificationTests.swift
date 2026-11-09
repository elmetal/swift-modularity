import Testing
@testable import swift_modularity

@Suite struct ClassificationTests {
    // Appendix A, step 7 with x = 5%, y = 1%, z = 50%.

    @Test func noCyclicGroupIsHierarchical() {
        #expect(ModularityAnalysis.classify(largest: 0, nextLargest: 0, total: 10, thresholds: .paper) == .hierarchical)
    }

    @Test func belowFourPercentIsHierarchical() {
        #expect(ModularityAnalysis.classify(largest: 3, nextLargest: 0, total: 100, thresholds: .paper) == .hierarchical)
    }

    @Test func exactlyFourPercentPassesTheFirstTest() {
        // nC ≥ (x − y)·N, even though 0.05 − 0.01 is slightly above 0.04 in binary.
        #expect(ModularityAnalysis.classify(largest: 4, nextLargest: 0, total: 100, thresholds: .paper) == .borderlineCorePeriphery)
    }

    @Test func betweenFourAndSixPercentIsBorderline() {
        #expect(ModularityAnalysis.classify(largest: 5, nextLargest: 2, total: 100, thresholds: .paper) == .borderlineCorePeriphery)
    }

    @Test func sixPercentOrMoreIsCorePeriphery() {
        #expect(ModularityAnalysis.classify(largest: 6, nextLargest: 4, total: 100, thresholds: .paper) == .corePeriphery)
    }

    @Test func similarlySizedGroupsAreMultiCore() {
        // 30 < 1.5 × 21
        #expect(ModularityAnalysis.classify(largest: 30, nextLargest: 21, total: 100, thresholds: .paper) == .multiCore)
        // 30 ≥ 1.5 × 20
        #expect(ModularityAnalysis.classify(largest: 30, nextLargest: 20, total: 100, thresholds: .paper) == .corePeriphery)
    }

    @Test func corePeripheryPartition() {
        // Control → Core (a ⇄ b) → Shared; Peripheral is unrelated.
        // 2 of 5 elements are in the Core: core-periphery.
        let graph = DependencyGraph(
            names: ["control", "a", "b", "shared", "peripheral"],
            dependencies: [("control", "a"), ("a", "b"), ("b", "a"), ("b", "shared")]
        )
        let analysis = ModularityAnalysis(graph: graph)
        #expect(analysis.architecture == .corePeriphery)
        #expect(analysis.view == .corePeriphery)
        #expect(analysis.cyclicGroups == [[1, 2]])
        #expect(analysis.groups == [.control, .core, .core, .shared, .peripheral])
        // Shared, Core, Peripheral, Control.
        #expect(analysis.dsmOrder.map { graph.nodes[$0].name } == ["shared", "a", "b", "peripheral", "control"])
        // VFI of the Core: control, a, b. VFO: a, b, shared.
        #expect(analysis.visibility.fanIn[1] == 3)
        #expect(analysis.visibility.fanOut[1] == 3)
    }

    @Test func hierarchicalSystemsUseTheMedianPartition() {
        let analysis = ModularityAnalysis(graph: GraphTests.paperExample)
        #expect(analysis.architecture == .hierarchical)
        #expect(analysis.view == .median)
        // VFI: A 1, B 2, C 2, D 3, E 3, F 4 → median 2.5. VFO: 6, 2, 3, 1, 2, 1 → median 2.
        #expect(analysis.medianFanIn == 2.5)
        #expect(analysis.medianFanOut == 2)
        // A: VFI 1 < 2.5, VFO 6 ≥ 2 → control. D: VFI 3, VFO 1 → shared. E: VFI 3, VFO 2 → central.
        #expect(analysis.groups == [.control, .control, .control, .shared, .central, .shared])
    }

    @Test func elementsUnrelatedToTheCoreReachingItsFansAreCentral() {
        // Core {a, b} (2 of 49 elements: borderline). x, unrelated to the Core, is on a chain
        // where it depends on 3 elements and is depended on by 3, like the Core.
        let graph = DependencyGraph(
            names: ["p", "a", "b", "q", "u1", "u2", "x", "v1", "v2"] + (0..<40).map { "filler\($0)" },
            dependencies: [
                ("p", "a"), ("a", "b"), ("b", "a"), ("b", "q"),
                ("u1", "u2"), ("u2", "x"), ("x", "v1"), ("v1", "v2"),
            ]
        )
        let analysis = ModularityAnalysis(graph: graph)
        #expect(analysis.architecture == .borderlineCorePeriphery)
        // Core VFI 3 (p, a, b), VFO 3 (a, b, q). x: VFI 3 (u1, u2, x), VFO 3 (x, v1, v2).
        #expect(analysis.groups[6] == .central)
    }

    @Test func thresholdsOutOfRange() {
        #expect(ArchitectureThresholds.paper.problem == nil)
        #expect(ArchitectureThresholds(size: 1, sensitivity: 0, dominance: 0).problem == nil)
        #expect(ArchitectureThresholds(size: 0, sensitivity: 0, dominance: 0.5).problem != nil)
        #expect(ArchitectureThresholds(size: 1.5, sensitivity: 0.01, dominance: 0.5).problem != nil)
        #expect(ArchitectureThresholds(size: 0.05, sensitivity: -0.01, dominance: 0.5).problem != nil)
        // y must stay below x, or the borderline band would include an empty Core.
        #expect(ArchitectureThresholds(size: 0.05, sensitivity: 0.05, dominance: 0.5).problem != nil)
        #expect(ArchitectureThresholds(size: 0.05, sensitivity: 0.01, dominance: -1).problem != nil)
        #expect(ArchitectureThresholds(size: .nan, sensitivity: 0.01, dominance: 0.5).problem != nil)
    }
}
