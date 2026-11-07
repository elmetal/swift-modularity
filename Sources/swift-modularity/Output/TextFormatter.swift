import Foundation

// MARK: - Text Output

/// Formats a report for reading in a terminal (or by an AI assistant).
public struct TextFormatter: Sendable {
    /// At most this many elements are listed per group; 0 lists all of them.
    public var limit: Int
    /// Whether to print the reordered DSM of modules with at most `matrixLimit` elements.
    public var showMatrix: Bool
    public var matrixLimit: Int

    public init(limit: Int = 10, showMatrix: Bool = false, matrixLimit: Int = 80) {
        self.limit = limit
        self.showMatrix = showMatrix
        self.matrixLimit = matrixLimit
    }

    public func format(_ report: ModularityReport) -> String {
        report.modules.map(format).joined(separator: "\n")
    }

    public func format(_ module: ModuleReport) -> String {
        var lines: [String] = []
        let level = module.level == .file ? "files" : "targets"
        var title = "\(module.name) (\(level))"
        if let directory = module.directory {
            title += " — \(directory)"
        }
        lines.append(title)
        lines.append("  \(module.elementCount) \(module.elementNoun), \(module.dependencyCount) dependencies")
        lines.append("  Propagation cost: \(Self.percent(module.propagationCost))")

        var architecture = "  Architecture: \(module.architecture.rawValue)"
        if module.largestCyclicGroupSize > 0 {
            architecture += " (largest cyclic group: \(module.largestCyclicGroupSize) \(module.elementNoun), \(Self.percent(module.largestCyclicGroupRatio))"
            if module.cyclicGroups.count > 1 {
                architecture += "; next: \(module.cyclicGroups[1].size)"
            }
            architecture += ")"
        } else {
            architecture += " (no cyclic groups)"
        }
        lines.append(architecture)

        let counts = ComponentGroup.dsmOrder.compactMap { group -> String? in
            let count = module.elements.filter { $0.group == group }.count
            return count == 0 ? nil : "\(Self.title(of: group, view: module.view)) \(count)"
        }
        if !counts.isEmpty {
            lines.append("  Partition (\(module.view.rawValue) view): " + counts.joined(separator: ", "))
        }

        if !module.cyclicGroups.isEmpty {
            lines.append("")
            lines.append("  Cyclic groups (every member depends on every other, directly or indirectly):")
            for (index, group) in module.cyclicGroups.enumerated() {
                lines.append("    \(index + 1). \(group.size) \(module.elementNoun)\(group.isCore ? " (Core)" : "")")
                for dependency in group.dependencies {
                    var line = "       \(dependency.from) → \(dependency.to)"
                    if let symbol = dependency.symbol, let lineNumber = dependency.line {
                        line += "  `\(symbol)` line \(lineNumber)"
                        if dependency.references > 1 {
                            line += " (+\(dependency.references - 1) more)"
                        }
                    }
                    lines.append(line)
                }
            }
        }

        if !module.elements.isEmpty {
            lines.append("")
            lines.append("  Elements (VFI: depended on by, VFO: depends on; both count the element itself):")
            let width = min(module.elements.map(\.name.count).max() ?? 0, 60)
            for group in ComponentGroup.dsmOrder {
                let members = module.elements.filter { $0.group == group }
                guard !members.isEmpty else { continue }
                lines.append("    \(Self.title(of: group, view: module.view)) (\(members.count)) — \(Self.explanation(of: group, view: module.view))")
                let shown = limit > 0 ? Array(members.prefix(limit)) : members
                for element in shown {
                    let name = element.name.padding(toLength: max(width, element.name.count), withPad: " ", startingAt: 0)
                    lines.append("      \(name)  VFI \(element.fanIn)  VFO \(element.fanOut)")
                }
                if shown.count < members.count {
                    lines.append("      … and \(members.count - shown.count) more (--limit 0 lists all)")
                }
            }
        }

        if showMatrix, module.elementCount > 0 {
            lines.append("")
            if module.elementCount <= matrixLimit {
                lines.append(contentsOf: matrix(module))
            } else {
                lines.append("  (DSM not shown: more than \(matrixLimit) \(module.elementNoun))")
            }
        }

        if !module.unreadableFiles.isEmpty {
            lines.append("")
            lines.append("  Unreadable files (skipped): " + module.unreadableFiles.joined(separator: ", "))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The reordered DSM: row i depends on column j. `x` direct, `.` indirect, `#` itself.
    func matrix(_ module: ModuleReport) -> [String] {
        let names = module.elements.map(\.name)
        let index = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        var direct = Array(repeating: Set<Int>(), count: names.count)
        for dependency in module.dependencies {
            if let from = index[dependency.from], let to = index[dependency.to] {
                direct[from].insert(to)
            }
        }
        // Visibility, from the direct dependencies (the matrix is small).
        let graph = DependencyGraph(names: names, dependencies: module.dependencies.map { ($0.from, $0.to) })
        let components = StronglyConnectedComponents(successors: graph.successors)
        let visibility = VisibilityMatrix(successors: graph.successors, components: components)

        var lines = ["  DSM (rows depend on columns; x direct, . indirect):"]
        let width = String(names.count).count
        for (row, name) in names.enumerated() {
            let cells = (0..<names.count).map { column -> String in
                if row == column { return "#" }
                if direct[row].contains(column) { return "x" }
                return visibility.contains(row: row, column: column) ? "." : " "
            }.joined()
            let number = String(row + 1).leftPadded(to: width)
            let group = module.elements[row].group.rawValue.prefix(4)
            lines.append("    \(number) \(group) |\(cells)| \(name)")
        }
        return lines
    }

    static func title(of group: ComponentGroup, view: PartitionView) -> String {
        let base: String
        switch group {
        case .shared: base = "Shared"
        case .core: base = "Core"
        case .central: base = "Central"
        case .peripheral: base = "Peripheral"
        case .control: base = "Control"
        }
        return view == .median && group != .central ? base + "-M" : base
    }

    static func explanation(of group: ComponentGroup, view: PartitionView) -> String {
        let reference = view == .corePeriphery ? "the Core" : "the medians"
        switch group {
        case .shared: return "depended on as widely as \(reference), depend on less"
        case .core: return "the largest cyclic group"
        case .central: return "at or above \(reference) in both"
        case .peripheral: return "below \(reference) in both"
        case .control: return "depend on as much as \(reference), depended on by fewer"
        }
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
