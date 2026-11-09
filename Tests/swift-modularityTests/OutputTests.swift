import Foundation
import Testing
@testable import swift_modularity

@Suite struct OutputTests {
    func cycleReport() -> ModularityReport {
        let graph = FileDependencyGraphBuilder().build(sources: [
            (name: "A.swift", source: "struct A { var b: B? }"),
            (name: "B.swift", source: "struct B {\n    var a: A?\n}"),
            (name: "C.swift", source: "struct C { var a: A }"),
        ])
        return ModularityReport(modules: [
            ModuleReport(name: "App", level: .file, directory: "Sources/App", analysis: ModularityAnalysis(graph: graph)),
        ])
    }

    @Test func textOutput() {
        let text = TextFormatter(showMatrix: true).format(cycleReport())
        #expect(text.contains("App (files) — Sources/App"))
        #expect(text.contains("3 files, 3 dependencies"))
        // VFO: A 2, B 2, C 3 → 7 / 9.
        #expect(text.contains("Propagation cost: 77.8%"))
        #expect(text.contains("Architecture: core-periphery (largest cyclic group: 2 files, 66.7%)"))
        #expect(text.contains("1. 2 files (Core): A.swift, B.swift"))
        #expect(text.contains("Removing one of these dependencies splits it:"))
        #expect(text.contains("A.swift → B.swift  `B` line 1 (1 reference): no cycle left"))
        #expect(text.contains("    1 core |#x | A.swift"))
        // C depends on A directly and on B through A.
        #expect(text.contains("    3 cont |x.#| C.swift"))
    }

    @Test func jsonRoundTrips() throws {
        let report = cycleReport()
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(ModularityReport.self, from: data) == report)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"architecture\":\"core-periphery\""))
        #expect(json.contains("\"schemaVersion\":1"))
    }

    @Test func xcodeNotesAtTheBestSplittingDependencies() {
        let output = DiagnosticFormatter.format(cycleReport(), style: .xcode)
        let lines = output.split(separator: "\n").map(String.init)
        // Both dependencies of the 2-file cycle split it completely.
        #expect(lines == [
            "A.swift:1:19: note: removing the dependency on B.swift (`B`, 1 reference) splits cyclic group 1 of 2 files in App (the Core): no cycle left [swift-modularity]",
            "B.swift:2:12: note: removing the dependency on A.swift (`A`, 1 reference) splits cyclic group 1 of 2 files in App (the Core): no cycle left [swift-modularity]",
        ])
    }

    @Test func githubNotices() {
        let output = DiagnosticFormatter.format(cycleReport(), style: .github)
        #expect(output.hasPrefix("::notice file=A.swift,line=1,col=19,title=Dependency that splits a cycle (swift-modularity)::removing"))
    }

    @Test func targetModulesHaveNoNotes() {
        let graph = DependencyGraph(names: ["a", "b"], dependencies: [("a", "b"), ("b", "a")])
        let report = ModularityReport(modules: [ModuleReport(name: "P", level: .target, directory: nil, analysis: ModularityAnalysis(graph: graph))])
        #expect(DiagnosticFormatter.format(report, style: .xcode).isEmpty)
    }

    @Test func extractionText() {
        let graph = FileDependencyGraphBuilder().build(sources: [
            (name: "App.swift", source: "func main() { _ = Log() }"),
            (name: "Util/Log.swift", source: "struct Log { var format = Format() }"),
            (name: "Util/Format.swift", source: "struct Format {}"),
        ])
        let report = ModularityReport(modules: [ModuleReport(name: "App", level: .file, directory: nil, analysis: ModularityAnalysis(graph: graph))])
        let text = TextFormatter().format(report)
        #expect(text.contains("Util/ (2 files): candidate lower target — depends on nothing else here; 1 dependency (1 reference) from other files would use it"))
        #expect(report.modules[0].extractionCandidates.map(\.directory) == ["Util/"])
    }

    @Test func blockingDependenciesFollowTheLimit() {
        // Dir/ uses 4 files outside it, and 5 files outside it use Dir/.
        let outside = (1...5).map { "O\($0).swift" }
        let graph = DependencyGraph(
            names: ["Dir/A.swift", "Dir/B.swift"] + outside,
            dependencies: outside.prefix(4).map { ("Dir/A.swift", $0) } + outside.map { ($0, "Dir/B.swift") }
        )
        let report = ModularityReport(modules: [ModuleReport(name: "App", level: .file, directory: nil, analysis: ModularityAnalysis(graph: graph))])
        let blocked = "blocked — as a lower target, remove 4 dependencies"
        let shortened = TextFormatter().format(report)
        #expect(shortened.contains(blocked))
        #expect(!shortened.contains("Dir/A.swift → O4.swift"))
        #expect(shortened.contains("… and 1 more (--limit 0 lists all)"))
        let all = TextFormatter(limit: 0).format(report)
        #expect(all.contains("Dir/A.swift → O4.swift"))
        #expect(!all.contains("… and"))
    }
}
