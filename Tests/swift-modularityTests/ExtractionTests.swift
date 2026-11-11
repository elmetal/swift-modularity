import Testing
@testable import swift_modularity

@Suite struct ExtractionTests {
    /// Features/ uses Core/ and App.swift uses both; Core/ uses Util/Log.swift through Core/B.swift.
    static let graph = DependencyGraph(
        names: ["App.swift", "Core/A.swift", "Core/B.swift", "Features/Profile/P.swift", "Features/Profile/Q.swift",
                "Util/Log.swift", "Util/Format.swift"],
        dependencies: [
            ("App.swift", "Features/Profile/P.swift"), ("App.swift", "Core/A.swift"),
            ("Features/Profile/P.swift", "Features/Profile/Q.swift"), ("Features/Profile/Q.swift", "Core/A.swift"),
            ("Core/A.swift", "Core/B.swift"), ("Core/B.swift", "Util/Log.swift"),
            ("Util/Log.swift", "Util/Format.swift"),
        ]
    )

    func candidates() -> [String: ExtractionCandidate] {
        Dictionary(uniqueKeysWithValues: Extraction.directoryCandidates(in: ModularityAnalysis(graph: Self.graph)).map { ($0.directory, $0) })
    }

    @Test func directoriesAtEveryDepthWithTwoOrMoreFiles() {
        #expect(Set(candidates().keys) == ["Core/", "Features/", "Features/Profile/", "Util/"])
    }

    @Test func lowerTarget() {
        let util = candidates()["Util/"]!
        #expect(util.canBeLowerTarget && !util.canBeUpperTarget)
        #expect(util.incoming.map { Self.graph.nodes[$0.from].name } == ["Core/B.swift"])
    }

    @Test func upperTarget() {
        let features = candidates()["Features/"]!
        #expect(features.canBeUpperTarget == false)  // App.swift depends on it
        let profile = candidates()["Features/Profile/"]!
        #expect(!profile.canBeLowerTarget && !profile.canBeUpperTarget)

        // Nothing outside Features/ depends on it, and it uses Core.swift.
        let graph = DependencyGraph(names: ["Core.swift", "Features/P.swift", "Features/Q.swift"],
                                    dependencies: [("Features/P.swift", "Features/Q.swift"), ("Features/Q.swift", "Core.swift")])
        let upper = Extraction.directoryCandidates(in: ModularityAnalysis(graph: graph))
        #expect(upper.map(\.directory) == ["Features/"])
        #expect(upper[0].canBeUpperTarget && !upper[0].canBeLowerTarget && !upper[0].isBlocked)
        #expect(upper[0].outgoing.map { graph.nodes[$0.to].name } == ["Core.swift"])
        #expect(upper[0].requiredFiles.map { graph.nodes[$0].name } == ["Core.swift"])
    }

    @Test func blockedWithRequiredFiles() {
        let core = candidates()["Core/"]!
        #expect(core.isBlocked)
        #expect(core.outgoing.map { Self.graph.nodes[$0.to].name } == ["Util/Log.swift"])
        // Moving Util/ with it would make a lower target.
        #expect(core.requiredFiles.map { Self.graph.nodes[$0].name } == ["Util/Log.swift", "Util/Format.swift"])
    }

    @Test func targetsFirstThenFewestBlockingDependencies() {
        let order = Extraction.directoryCandidates(in: ModularityAnalysis(graph: Self.graph)).map(\.directory)
        #expect(order.first == "Util/")
        // Blocked, each by 1 dependency in its cheaper direction: Core/ (1 out, 2 in), Features/
        // (1 out, 1 in), Features/Profile/ (1 out, 1 in); ties by size, then name.
        #expect(Array(order.dropFirst()) == ["Core/", "Features/", "Features/Profile/"])
    }

    @Test func noCycleCrossesABoundaryInAnAcyclicGraph() {
        #expect(candidates().values.allSatisfy { $0.splitGroups.isEmpty })
    }

    @Test func removingTheBlockingDependenciesSplitsTheGroupAtTheBoundary() {
        // One cyclic group of 7 files: Dir/ holds the cycle a ⇄ b and o1 ⇄ o2 ⇄ o3 is outside;
        // Dir/ and the rest use each other through 2 dependencies each way, and x.swift ⇄ o1
        // stays outside too.
        let graph = DependencyGraph(
            names: ["Dir/a.swift", "Dir/b.swift", "Dir/c.swift", "o1.swift", "o2.swift", "o3.swift", "x.swift"],
            dependencies: [
                ("Dir/a.swift", "Dir/b.swift"), ("Dir/b.swift", "Dir/a.swift"), ("Dir/b.swift", "Dir/c.swift"),
                ("o1.swift", "o2.swift"), ("o2.swift", "o3.swift"), ("o3.swift", "o1.swift"),
                ("o1.swift", "x.swift"), ("x.swift", "o1.swift"),
                ("Dir/c.swift", "o1.swift"), ("Dir/a.swift", "o2.swift"),
                ("o3.swift", "Dir/a.swift"), ("x.swift", "Dir/b.swift"),
            ]
        )
        let analysis = ModularityAnalysis(graph: graph)
        #expect(analysis.cyclicGroups.map(\.count) == [7])
        let dir = Extraction.directoryCandidates(in: analysis).first { $0.directory == "Dir/" }!
        #expect(dir.isBlocked)
        #expect(dir.splitGroups == [.init(group: 0, groupSize: 7, remainingGroupSizes: [4, 2])])
        // The same groups are left removing the incoming dependencies instead.
        #expect(CycleBreaking.remainingGroupSizes(in: graph, group: analysis.cyclicGroups[0], removing: dir.incoming) == [4, 2])
    }

    @Test func aBlockedDirectoryOutsideTheCycleSplitsNothing() {
        // Dir/ uses a ⇄ b and b uses Dir/, but nothing in Dir/ leads back: no cycle crosses it.
        let graph = DependencyGraph(
            names: ["Dir/p.swift", "Dir/q.swift", "a.swift", "b.swift", "c.swift"],
            dependencies: [("a.swift", "b.swift"), ("b.swift", "a.swift"), ("Dir/p.swift", "a.swift"), ("c.swift", "Dir/q.swift")]
        )
        let dir = Extraction.directoryCandidates(in: ModularityAnalysis(graph: graph)).first { $0.directory == "Dir/" }!
        #expect(dir.isBlocked)
        #expect(dir.splitGroups.isEmpty)
    }

    @Test func theWholeModuleIsNotACandidate() {
        let graph = DependencyGraph(names: ["Sources/A.swift", "Sources/B.swift"], dependencies: [("Sources/A.swift", "Sources/B.swift")])
        #expect(Extraction.directoryCandidates(in: ModularityAnalysis(graph: graph)).isEmpty)
    }
}
