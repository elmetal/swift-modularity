import Foundation
import Testing
@testable import swift_modularity

@Suite struct ConfigTests {
    @Test func configFile() throws {
        let config = try ModularityConfig.parse("""
        # comment
        exclude = [
          "**/Generated/**",  # generated
          "Tests",
        ]
        include-tests = true
        size_threshold = 0.1
        limit = 0
        unknown = 1
        """)
        #expect(config.exclude == ["**/Generated/**", "Tests"])
        #expect(config.includeTests == true)
        #expect(config.thresholds == ArchitectureThresholds(size: 0.1, sensitivity: 0.01, dominance: 0.5))
        #expect(config.limit == 0)
        #expect(config.unknownKeys == ["unknown"])

        var commandLine = ModularityConfig()
        commandLine.includeTests = false
        commandLine.exclude = ["Extra"]
        let merged = commandLine.overriding(config)
        #expect(merged.includeTests == false)
        #expect(merged.exclude == ["**/Generated/**", "Tests", "Extra"])
        #expect(merged.limit == 0)

        #expect(throws: ModularityConfig.ParseError.self) { try ModularityConfig.parse("limit = many") }
    }

    @Test func findStopsAtTheRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modularity-\(UUID().uuidString)/a/b")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }

        #expect(ModularityConfig.find(from: "/") == nil)
        #expect(ModularityConfig.find(from: directory.path) == nil)

        let file = directory.deletingLastPathComponent().appendingPathComponent(ModularityConfig.fileName)
        try "".write(to: file, atomically: true, encoding: .utf8)
        #expect(ModularityConfig.find(from: directory.path) == file.standardizedFileURL.path)
    }
}
