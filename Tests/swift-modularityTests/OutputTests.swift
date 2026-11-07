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

    @Test func xcodeDiagnosticsPointAtTheReferences() {
        let output = DiagnosticFormatter.format(cycleReport(), style: .xcode)
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("A.swift:1:19: warning: `B` (B.swift) depends back on this file"))
        #expect(lines[1].hasPrefix("B.swift:2:12: warning: `A` (A.swift) depends back on this file"))
        #expect(lines.allSatisfy { $0.contains("cyclic group 1 of 2 files in App, the Core (66.7% of the module) [swift-modularity]") })
    }

    @Test func githubDiagnosticsAreEscaped() {
        let output = DiagnosticFormatter.format(cycleReport(), style: .github)
        #expect(output.hasPrefix("::warning file=A.swift,line=1,col=19,title=Dependency cycle (swift-modularity)::"))
    }

    @Test func targetModulesHaveNoDiagnostics() {
        let graph = DependencyGraph(names: ["a", "b"], dependencies: [("a", "b"), ("b", "a")])
        let report = ModularityReport(modules: [ModuleReport(name: "P", level: .target, directory: nil, analysis: ModularityAnalysis(graph: graph))])
        #expect(DiagnosticFormatter.format(report, style: .xcode).isEmpty)
    }

    @Test func textOutput() {
        let text = TextFormatter(showMatrix: true).format(cycleReport())
        #expect(text.contains("App (files) — Sources/App"))
        #expect(text.contains("3 files, 3 dependencies"))
        // VFO: A 2, B 2, C 3 → 7 / 9.
        #expect(text.contains("Propagation cost: 77.8%"))
        #expect(text.contains("Architecture: core-periphery (largest cyclic group: 2 files, 66.7%)"))
        #expect(text.contains("1. 2 files (Core)"))
        #expect(text.contains("A.swift → B.swift  `B` line 1"))
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
    }

    @Test func qualityGate() {
        let report = cycleReport()
        #expect(QualityGate().violations(in: report).isEmpty)
        #expect(QualityGate(failOnCycles: true).violations(in: report) == ["App (files): 1 cyclic group(s) of 2 files"])
        #expect(QualityGate(maxPropagationCost: 0.8).violations(in: report).isEmpty)
        #expect(QualityGate(maxPropagationCost: 0.5).violations(in: report) == ["App (files): propagation cost 77.8% is above 50.0%"])
    }
}
