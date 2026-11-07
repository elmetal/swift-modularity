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
}
