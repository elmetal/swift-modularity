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

    @Test func parsesSourcesAndExclude() throws {
        let json = """
        {"name": "Demo", "targets": [
          {"name": "Core", "type": "regular", "path": "Core", "sources": ["Kept.swift", "Main"], "exclude": [], "dependencies": []},
          {"name": "App", "type": "regular", "path": "App", "sources": null, "exclude": ["Old"], "dependencies": []}
        ]}
        """
        let package = try PackageLoader.parseDumpPackage(Data(json.utf8), packageDirectory: "/tmp/Demo")
        #expect(package.targets.map(\.sources) == [["Kept.swift", "Main"], nil])
        #expect(package.targets.map(\.exclude) == [nil, ["Old"]])
    }

    @Test func swiftFilesFollowSourcesAndExclude() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PackageTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["A.swift", "Main/B.swift", "Main/Old/C.swift", "Mainly/D.swift", "Generated/E.swift"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct S {}".write(to: url, atomically: true, encoding: .utf8)
        }
        func files(sources: [String]?, exclude: [String]?, patterns: [String] = []) throws -> [String] {
            let target = PackageDescription.Target(name: "T", kind: "regular", directory: root.path, dependencies: [],
                                                   sources: sources, exclude: exclude)
            return try target.swiftFiles(excluding: patterns.map(ExcludePattern.init))
                .map { String($0.dropFirst(root.path.count + 1)) }
        }
        #expect(try files(sources: nil, exclude: nil)
                == ["A.swift", "Generated/E.swift", "Main/B.swift", "Main/Old/C.swift", "Mainly/D.swift"])
        // A directory covers the files under it, not those of a directory whose name starts the same.
        #expect(try files(sources: ["./Main/", "A.swift"], exclude: ["Main/Old"]) == ["A.swift", "Main/B.swift"])
        #expect(try files(sources: nil, exclude: ["Main", "A.swift"], patterns: ["Generated"]) == ["Mainly/D.swift"])
        // The plugin lists every file; none for a target without Swift files.
        #expect(try files(sources: [], exclude: nil).isEmpty)
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

    /// Runs `script` with `sh` and returns why it failed, as `PackageLoader` reports it.
    func failureReason(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        return PackageLoader.failureReason(errors: Data(), output: Data(), process: process)
    }

    @Test func failureReasonFallsBackToOutputThenTermination() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        try process.run()
        process.waitUntilExit()
        #expect(PackageLoader.failureReason(errors: Data("error: bad\n".utf8), output: Data("out".utf8), process: process) == "error: bad\nout")
        #expect(PackageLoader.failureReason(errors: Data(" \n".utf8), output: Data("error: on stdout\n".utf8), process: process) == "error: on stdout")
        #expect(try failureReason("exit 3") == "exited with status 3, with no output")
        #expect(try failureReason("kill -9 $$") == "terminated by signal 9, with no output")
    }
}
