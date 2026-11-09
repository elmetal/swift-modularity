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
        if !module.isPartitioned, module.elementCount > 0 {
            lines.append("  Partition: none (no dependencies between \(module.elementNoun))")
        } else if !counts.isEmpty {
            lines.append("  Partition (\(module.view.rawValue) view): " + counts.joined(separator: ", "))
        }

        if !module.cyclicGroups.isEmpty {
            lines.append("")
            lines.append("  Cyclic groups (every member depends on every other, directly or indirectly):")
            for (index, group) in module.cyclicGroups.enumerated() {
                let shownMembers = limit > 0 ? Array(group.members.prefix(limit)) : group.members
                var header = "    \(index + 1). \(group.size) \(module.elementNoun)\(group.isCore ? " (Core)" : ""): "
                header += shownMembers.joined(separator: ", ")
                if shownMembers.count < group.members.count {
                    header += " … and \(group.members.count - shownMembers.count) more"
                }
                lines.append(header)
                if group.breakingDependencies.isEmpty {
                    lines.append("       No single dependency splits it (\(group.dependencies.count) dependencies inside).")
                    continue
                }
                lines.append("       Removing one of these dependencies splits it:")
                let shown = limit > 0 ? Array(group.breakingDependencies.prefix(limit)) : group.breakingDependencies
                for breaking in shown {
                    lines.append("         " + Self.describe(breaking, groupSize: group.size, noun: module.elementNoun))
                }
                if shown.count < group.breakingDependencies.count {
                    lines.append("         … and \(group.breakingDependencies.count - shown.count) more (--limit 0 lists all)")
                }
            }
        }

        if !module.extractionCandidates.isEmpty {
            lines.append("")
            lines.append(contentsOf: extraction(module))
        }

        if !module.elements.isEmpty {
            lines.append("")
            lines.append("  Elements (VFI: depended on by, VFO: depends on; both count the element itself):")
            let width = min(module.elements.map(\.name.count).max() ?? 0, 60)
            func list(_ members: [ModuleReport.Element], indent: String) {
                let shown = limit > 0 ? Array(members.prefix(limit)) : members
                for element in shown {
                    let name = element.name.padding(toLength: max(width, element.name.count), withPad: " ", startingAt: 0)
                    lines.append("\(indent)\(name)  VFI \(element.fanIn)  VFO \(element.fanOut)")
                }
                if shown.count < members.count {
                    lines.append("\(indent)… and \(members.count - shown.count) more (--limit 0 lists all)")
                }
            }
            if module.isPartitioned {
                for group in ComponentGroup.dsmOrder {
                    let members = module.elements.filter { $0.group == group }
                    guard !members.isEmpty else { continue }
                    lines.append("    \(Self.title(of: group, view: module.view)) (\(members.count)) — \(Self.explanation(of: group, view: module.view))")
                    list(members, indent: "      ")
                }
            } else {
                // No groups: every element only counts itself.
                list(module.elements, indent: "    ")
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

    /// Directories that could become targets, then the blocked ones with what blocks them.
    func extraction(_ module: ModuleReport) -> [String] {
        var lines = ["  Directories as targets (dependencies may cross a target's boundary in one direction only; dependencies the tool cannot see may block a candidate):"]
        let shown = limit > 0 ? Array(module.extractionCandidates.prefix(limit)) : module.extractionCandidates
        for candidate in shown {
            let files = "\(candidate.directory) (\(candidate.files.count) files)"
            switch (candidate.canBeLowerTarget, candidate.canBeUpperTarget) {
            case (true, true):
                lines.append("    \(files): independent — no dependency crosses its boundary")
            case (true, false):
                lines.append("    \(files): candidate lower target — depends on nothing else here; "
                             + "\(Self.count(candidate.incoming)) from other files would use it")
            case (false, true):
                lines.append("    \(files): candidate higher target — nothing else here depends on it; "
                             + "it uses \(Self.count(candidate.outgoing)) into the rest")
            case (false, false):
                // Show the direction with fewer dependencies to remove.
                let lower = candidate.outgoing.count <= candidate.incoming.count
                let blocking = lower ? candidate.outgoing : candidate.incoming
                var text = "    \(files): blocked — as a \(lower ? "lower" : "higher") target, remove \(Self.count(blocking))"
                if lower, !candidate.requiredFiles.isEmpty {
                    text += ", or move the \(candidate.requiredFiles.count) file\(candidate.requiredFiles.count == 1 ? "" : "s") it needs with it"
                }
                lines.append(text + ":")
                // A few by default, as each candidate is one line among many; all with --limit 0.
                let shownBlocking = limit > 0 ? Array(blocking.prefix(3)) : blocking
                for dependency in shownBlocking {
                    var line = "        \(dependency.from) → \(dependency.to)"
                    if let symbol = dependency.symbol, let number = dependency.line {
                        line += "  `\(symbol)` line \(number)"
                    }
                    lines.append(line + " (\(dependency.references) reference\(dependency.references == 1 ? "" : "s"))")
                }
                if shownBlocking.count < blocking.count {
                    lines.append("        … and \(blocking.count - shownBlocking.count) more (--limit 0 lists all)")
                }
                if candidate.splitGroups.isEmpty {
                    lines.append("        No cycle crosses its boundary.")
                }
                for split in candidate.splitGroups {
                    lines.append("        Removing them all splits cyclic group \(split.group) (\(split.size) \(module.elementNoun)): "
                                 + Self.remaining(split.remainingGroups, noun: module.elementNoun))
                }
            }
        }
        if shown.count < module.extractionCandidates.count {
            lines.append("    … and \(module.extractionCandidates.count - shown.count) more directories (--limit 0 lists all)")
        }
        return lines
    }

    /// "3 dependencies (12 references)"
    static func count(_ dependencies: [ModuleReport.Dependency]) -> String {
        let references = dependencies.map(\.references).reduce(0, +)
        return "\(dependencies.count) dependenc\(dependencies.count == 1 ? "y" : "ies") (\(references) reference\(references == 1 ? "" : "s"))"
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
            let group = module.isPartitioned ? module.elements[row].group.rawValue.prefix(4) : "    "
            lines.append("    \(number) \(group) |\(cells)| \(name)")
        }
        return lines
    }

    /// "A.swift → B.swift  `Foo` line 12 (3 references): largest group left 9 files (9 + 2)"
    static func describe(_ breaking: ModuleReport.BreakingDependencyReport, groupSize: Int, noun: String) -> String {
        describe(breaking.dependency) + ": " + remaining(breaking.remainingGroups, noun: noun)
    }

    /// "A.swift → B.swift  `Foo` line 12 (3 references)"
    static func describe(_ dependency: ModuleReport.Dependency) -> String {
        var text = "\(dependency.from) → \(dependency.to)"
        if let symbol = dependency.symbol, let line = dependency.line {
            text += "  `\(symbol)` line \(line)"
        }
        return text + " (\(dependency.references) reference\(dependency.references == 1 ? "" : "s"))"
    }

    /// "largest group left 9 files (9 + 2)", or "no cycle left"
    static func remaining(_ groups: [Int], noun: String) -> String {
        guard let largest = groups.first else { return "no cycle left" }
        var text = "largest group left \(largest) \(noun)"
        if groups.count > 1 {
            text += " (" + groups.map(String.init).joined(separator: " + ") + ")"
        }
        return text
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
