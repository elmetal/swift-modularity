import Foundation

// MARK: - Diff Output

/// Formats a `ModularityDiff` for reading in a terminal, or as notes at the new dependencies that
/// close or grow cyclic groups (Xcode and GitHub Actions).
public struct DiffTextFormatter: Sendable {
    /// At most this many elements or dependencies are listed per list; 0 lists all of them.
    public var limit: Int

    public init(limit: Int = 10) {
        self.limit = limit
    }

    public func format(_ diff: ModularityDiff) -> String {
        var lines = ["Comparing \(Self.describe(diff.base)) with \(Self.describe(diff.head))"]
        for module in diff.modules {
            lines.append("")
            lines += format(module)
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ side: ModularityDiff.Side) -> String {
        guard let commit = side.commit else { return side.name }
        return "\(side.name) (\(commit.prefix(10)))"
    }

    func format(_ module: ModuleDiff) -> [String] {
        let noun = module.elementNoun
        var title = "\(module.name) (\(noun))"
        if let directory = module.directory { title += " — \(directory)" }
        switch module.status {
        case .added: title += ": new"
        case .removed: title += ": removed"
        case .compared: if module.isUnchanged { return [title + ": no change"] }
        }
        var lines = [title]

        var count = "  \(noun.capitalized): " + Self.change(module.base?.elementCount, module.head?.elementCount)
        let elementChanges = [module.addedElements.isEmpty ? nil : "+\(module.addedElements.count)",
                              module.removedElements.isEmpty ? nil : "−\(module.removedElements.count)"].compactMap { $0 }
        if !elementChanges.isEmpty { count += " (\(elementChanges.joined(separator: ", ")))" }
        lines.append(count)
        if module.status == .compared {
            lines += list("    added: ", module.addedElements)
            lines += list("    removed: ", module.removedElements)
        }

        var dependencies = "  Dependencies: " + Self.change(module.base?.dependencyCount, module.head?.dependencyCount)
        if module.status == .compared && !(module.addedDependencies.isEmpty && module.removedDependencies.isEmpty) {
            dependencies += " (+\(module.addedDependencies.count), −\(module.removedDependencies.count))"
        }
        lines.append(dependencies)

        var cost = "  Propagation cost: " + Self.change(module.base.map { TextFormatter.percent($0.propagationCost) },
                                                        module.head.map { TextFormatter.percent($0.propagationCost) })
        if let base = module.base, let head = module.head, base.propagationCost != head.propagationCost {
            let points = (head.propagationCost - base.propagationCost) * 100
            cost += String(format: " (%@%.1f points)", points > 0 ? "+" : "−", abs(points))
        }
        lines.append(cost)
        lines.append("  Architecture: " + Self.change(module.base?.architecture.rawValue, module.head?.architecture.rawValue))
        lines.append("  Largest cyclic group: " + Self.change(module.base?.largestCyclicGroupSize, module.head?.largestCyclicGroupSize) + " \(noun)")

        guard !module.cyclicGroups.isEmpty else { return lines }
        lines.append("")
        lines.append("  Cyclic groups that changed:")
        for change in module.cyclicGroups {
            lines += format(change, noun: noun)
        }
        return lines
    }

    func format(_ change: ModuleDiff.CyclicGroupChange, noun: String) -> [String] {
        var lines: [String] = []
        switch change.kind {
        case .new:
            lines.append("    New: group \(change.headGroup!), \(change.headSize) \(noun): " + shown(change.members))
        case .grown, .changed, .shrunk:
            let verb = change.kind == .grown ? "Grown" : change.kind == .shrunk ? "Shrunk" : "Changed"
            lines.append("    \(verb): group \(change.headGroup!) (was \(change.baseGroup!)), \(change.baseSize) → \(change.headSize) \(noun)")
            lines += list("      joined: ", change.joined)
            lines += list("      left: ", change.left)
        case .resolved:
            lines.append("    No longer a cycle: group \(change.baseGroup!) of \(change.baseSize) \(noun): " + shown(change.members))
        }
        if !change.newDependencies.isEmpty {
            lines.append("      New dependencies inside:")
            let dependencies = limit > 0 ? Array(change.newDependencies.prefix(limit)) : change.newDependencies
            for new in dependencies {
                var line = "        " + TextFormatter.describe(new.dependency)
                if let remaining = new.remainingGroups {
                    line += ": removing it splits the group, " + TextFormatter.remaining(remaining, noun: noun)
                }
                lines.append(line)
            }
            if dependencies.count < change.newDependencies.count {
                lines.append("        … and \(change.newDependencies.count - dependencies.count) more (--limit 0 lists all)")
            }
        }
        return lines
    }

    private func shown(_ names: [String]) -> String {
        let shown = limit > 0 ? Array(names.prefix(limit)) : names
        var text = shown.joined(separator: ", ")
        if shown.count < names.count { text += " … and \(names.count - shown.count) more" }
        return text
    }

    private func list(_ label: String, _ names: [String]) -> [String] {
        names.isEmpty ? [] : [label + shown(names)]
    }

    static func change<T: CustomStringConvertible & Equatable>(_ base: T?, _ head: T?) -> String {
        switch (base, head) {
        case let (base?, head?): return base == head ? "\(head)" : "\(base) → \(head)"
        case let (nil, head?): return "\(head)"
        case let (base?, nil): return "\(base)"
        case (nil, nil): return "-"
        }
    }
}

extension DiagnosticFormatter {
    /// A note at each new dependency that closes or grows a cyclic group: the ones whose removal
    /// splits the group, else every new dependency inside it.
    public static func format(_ diff: ModularityDiff, style: Style, relativeTo baseDirectory: String? = nil) -> String {
        var lines: [String] = []
        for module in diff.modules where module.level == .file {
            for change in module.cyclicGroups where [.new, .grown, .changed].contains(change.kind) {
                let splitting = change.newDependencies.filter { $0.remainingGroups != nil }
                for new in splitting.isEmpty ? change.newDependencies : splitting {
                    let dependency = new.dependency
                    let path = FileDependencyGraphBuilder.displayPath(module.headPaths[dependency.from] ?? dependency.from, relativeTo: baseDirectory)
                    let text = message(for: new, change: change, module: module, base: diff.base)
                    lines.append(note(text, title: "New dependency in a cycle (swift-modularity)", path: path,
                                      at: dependency, style: style))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "the new dependency on Parser.swift (`Parser`, 1 reference) closes cyclic group 2 of 3 files
    /// in App, which is new since main...HEAD: removing it splits the group, no cycle left
    /// [swift-modularity]"
    static func message(for new: ModuleDiff.NewDependency, change: ModuleDiff.CyclicGroupChange, module: ModuleDiff, base: ModularityDiff.Side) -> String {
        let dependency = new.dependency
        var text = "the new dependency on \(dependency.to) ("
        if let symbol = dependency.symbol { text += "`\(symbol)`, " }
        text += "\(dependency.references) reference\(dependency.references == 1 ? "" : "s")) "
        text += new.remainingGroups == nil ? "is inside" : "closes"
        text += " cyclic group \(change.headGroup!) of \(change.headSize) files in \(module.name), which "
        text += change.kind == .new ? "is new since \(base.name)" : "had \(change.baseSize) files in \(base.name)"
        if let remaining = new.remainingGroups {
            text += ": removing it splits the group, " + TextFormatter.remaining(remaining, noun: "files")
        }
        return text + " [swift-modularity]"
    }
}
