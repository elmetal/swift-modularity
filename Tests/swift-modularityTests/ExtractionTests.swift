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

    @Test func theWholeModuleIsNotACandidate() {
        let graph = DependencyGraph(names: ["Sources/A.swift", "Sources/B.swift"], dependencies: [("Sources/A.swift", "Sources/B.swift")])
        #expect(Extraction.directoryCandidates(in: ModularityAnalysis(graph: graph)).isEmpty)
    }
}
