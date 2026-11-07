import Foundation
import Testing
@testable import swift_modularity

@Suite struct PackageTests {
    @Test func parsesDumpPackage() throws {
        let json = """
        {"name": "Demo", "targets": [
          {"name": "Core", "type": "regular", "path": null, "dependencies": [
            {"product": ["SwiftSyntax", "swift-syntax", null, null]}]},
          {"name": "App", "type": "executable", "path": "Custom/App", "dependencies": [
            {"byName": ["Core", null]}, {"byName": ["ArgumentParser", null]}]},
          {"name": "CoreTests", "type": "test", "dependencies": [{"target": ["Core", null]}]},
          {"name": "Plugin", "type": "plugin", "dependencies": [{"byName": ["App", null]}]}
        ]}
        """
        let package = try PackageLoader.parseDumpPackage(Data(json.utf8), packageDirectory: "/tmp/Demo")
        #expect(package.name == "Demo")
        #expect(package.targets.map(\.dependencies) == [[], ["Core"], ["Core"], ["App"]])
        #expect(package.targets[1].directory == "/tmp/Demo/Custom/App")
        #expect(!package.targets[3].isSourceTarget)

        let graph = package.targetGraph(of: package.targets.filter(\.isSourceTarget))
        // Only App has a directory: the default ones (Sources/Core, Tests/CoreTests) do not exist.
        #expect(package.targets.map(\.directory) == [nil, "/tmp/Demo/Custom/App", nil, nil])
        #expect(graph.nodes.map(\.name) == ["App"])
        #expect(graph.edges.isEmpty)
    }

    @Test func targetGraph() {
        let package = PackageDescription(name: "P", directory: "/p", targets: [
            .init(name: "App", kind: "executable", directory: "/p/Sources/App", dependencies: ["Feature", "Core"]),
            .init(name: "Feature", kind: "regular", directory: "/p/Sources/Feature", dependencies: ["Core"]),
            .init(name: "Core", kind: "regular", directory: "/p/Sources/Core", dependencies: []),
        ])
        let analysis = ModularityAnalysis(graph: package.targetGraph(of: package.targets))
        // VFO: App 3, Feature 2, Core 1 → 6 / 9.
        #expect(abs(analysis.propagationCost - 6.0 / 9.0) < 1e-12)
    }
}
