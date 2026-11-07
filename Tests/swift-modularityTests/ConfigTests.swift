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
        fail-on-cycles = true
        max_propagation_cost = 0.25
        size_threshold = 0.1
        limit = 0
        unknown = 1
        """)
        #expect(config.exclude == ["**/Generated/**", "Tests"])
        #expect(config.failOnCycles == true)
        #expect(config.maxPropagationCost == 0.25)
        #expect(config.thresholds == ArchitectureThresholds(size: 0.1, sensitivity: 0.01, dominance: 0.5))
        #expect(config.limit == 0)
        #expect(config.unknownKeys == ["unknown"])

        var commandLine = ModularityConfig()
        commandLine.failOnCycles = false
        commandLine.exclude = ["Extra"]
        let merged = commandLine.overriding(config)
        #expect(merged.failOnCycles == false)
        #expect(merged.exclude == ["**/Generated/**", "Tests", "Extra"])
        #expect(merged.maxPropagationCost == 0.25)

        #expect(throws: ModularityConfig.ParseError.self) { try ModularityConfig.parse("limit = many") }
    }
}
