// MARK: - Quality Gate

/// Conditions that make `swift-modularity-cli` exit with status 1, for CI.
public struct QualityGate: Sendable, Equatable {
    /// Fail when a module has a cyclic group.
    public var failOnCycles: Bool
    /// Fail when a module's propagation cost is above this value (0...1).
    public var maxPropagationCost: Double?

    public init(failOnCycles: Bool = false, maxPropagationCost: Double? = nil) {
        self.failOnCycles = failOnCycles
        self.maxPropagationCost = maxPropagationCost
    }

    /// One message per violated condition, per module.
    public func violations(in report: ModularityReport) -> [String] {
        var messages: [String] = []
        for module in report.modules {
            let label = "\(module.name) (\(module.level == .file ? "files" : "targets"))"
            if failOnCycles, !module.cyclicGroups.isEmpty {
                let sizes = module.cyclicGroups.map { String($0.size) }.joined(separator: ", ")
                messages.append("\(label): \(module.cyclicGroups.count) cyclic group(s) of \(sizes) \(module.elementNoun)")
            }
            if let maxPropagationCost, module.propagationCost > maxPropagationCost {
                messages.append("\(label): propagation cost \(TextFormatter.percent(module.propagationCost)) is above \(TextFormatter.percent(maxPropagationCost))")
            }
        }
        return messages
    }
}
