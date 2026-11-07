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
}
