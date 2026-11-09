import Foundation

// MARK: - Modularity Diff

/// The changes between two reports of the same code: what `swift-modularity-cli diff` writes.
///
/// Modules are matched by level and name, elements by name and dependencies by their two ends.
/// A renamed file is a file removed and a file added.
public struct ModularityDiff: Sendable, Codable, Equatable {
    /// One side of the comparison.
    public struct Side: Sendable, Codable, Equatable {
        /// How the side was given: "origin/main...HEAD", "v1.0", "working tree".
        public var name: String
        /// The commit analyzed, or nil for the working tree.
        public var commit: String?

        public init(name: String, commit: String?) {
            self.name = name
            self.commit = commit
        }
    }

    /// The version of the JSON output: `ModularityReport.currentSchemaVersion`, shared by every
    /// command.
    public var schemaVersion: Int
    public var base: Side
    public var head: Side
    public var modules: [ModuleDiff]

    public init(base: Side, head: Side, modules: [ModuleDiff]) {
        self.schemaVersion = ModularityReport.currentSchemaVersion
        self.base = base
        self.head = head
        self.modules = modules
    }

    /// Compares the modules of two reports, in the order of `head` (then the removed ones).
    public init(base baseReport: ModularityReport, head headReport: ModularityReport, baseSide: Side, headSide: Side) {
        func key(_ module: ModuleReport) -> String { "\(module.level.rawValue)/\(module.name)" }
        let baseModules = Dictionary(baseReport.modules.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let headKeys = Set(headReport.modules.map(key))
        var modules = headReport.modules.map { ModuleDiff(base: baseModules[key($0)], head: $0) }
        modules += baseReport.modules.filter { !headKeys.contains(key($0)) }.map { ModuleDiff(base: $0, head: nil) }
        self.init(base: baseSide, head: headSide, modules: modules)
    }
}

/// The changes in one module.
public struct ModuleDiff: Sendable, Codable, Equatable {
    public typealias Dependency = ModuleReport.Dependency

    /// The measures of one side.
    public struct Summary: Sendable, Codable, Equatable {
        public var elementCount: Int
        public var dependencyCount: Int
        public var propagationCost: Double
        public var architecture: ArchitectureType
        public var largestCyclicGroupSize: Int
        public var cyclicGroupCount: Int

        public init(_ module: ModuleReport) {
            elementCount = module.elementCount
            dependencyCount = module.dependencyCount
            propagationCost = module.propagationCost
            architecture = module.architecture
            largestCyclicGroupSize = module.largestCyclicGroupSize
            cyclicGroupCount = module.cyclicGroups.count
        }
    }

    /// A cyclic group that appeared, changed members or disappeared.
    public struct CyclicGroupChange: Sendable, Codable, Equatable {
        public enum Kind: String, Sendable, Codable {
            /// No two of its members were in one group before.
            case new
            /// Members joined the group it continues, and none left.
            case grown
            /// Members joined and others left.
            case changed
            /// Members left, and none joined.
            case shrunk
            /// No two of its members are in one group any more.
            case resolved
        }

        public var kind: Kind
        /// The 1-based number of the group in the base and head reports.
        public var baseGroup: Int?
        public var headGroup: Int?
        public var baseSize: Int
        public var headSize: Int
        /// The members of the head group, or of the base group when it was resolved.
        public var members: [String]
        /// Members that are in the head group and not in the base group it continues.
        public var joined: [String]
        /// Members of the base group that are not in the head group.
        public var left: [String]
        /// Dependencies between members of the head group that the base did not have, the ones
        /// whose removal splits the group first.
        public var newDependencies: [NewDependency]
    }

    /// A dependency added inside a cyclic group.
    public struct NewDependency: Sendable, Codable, Equatable {
        public var dependency: Dependency
        /// The sizes of the cyclic groups left without the dependency, if its removal splits the
        /// group (see `ModuleReport.BreakingDependencyReport`).
        public var remainingGroups: [Int]?
    }

    public enum Status: String, Sendable, Codable {
        case added, removed, compared
    }

    public var name: String
    public var level: ModuleReport.Level
    public var status: Status
    /// The head report's directory, else the base report's.
    public var directory: String?
    public var base: Summary?
    public var head: Summary?
    public var addedElements: [String]
    public var removedElements: [String]
    public var addedDependencies: [Dependency]
    public var removedDependencies: [Dependency]
    /// The changed groups: new, grown and changed by head size, then shrunk, then resolved.
    public var cyclicGroups: [CyclicGroupChange]
    /// Paths of the head elements, for diagnostics.
    public var headPaths: [String: String]

    /// Whether nothing measured changed.
    public var isUnchanged: Bool {
        status == .compared && base == head && addedElements.isEmpty && removedElements.isEmpty
            && addedDependencies.isEmpty && removedDependencies.isEmpty && cyclicGroups.isEmpty
    }

    public var elementNoun: String { level == .file ? "files" : "targets" }

    public init(base: ModuleReport?, head: ModuleReport?) {
        precondition(base != nil || head != nil)
        let module = (head ?? base)!
        name = module.name
        level = module.level
        directory = head?.directory ?? base?.directory
        status = base == nil ? .added : head == nil ? .removed : .compared
        self.base = base.map(Summary.init)
        self.head = head.map(Summary.init)
        headPaths = Dictionary((head?.elements ?? []).compactMap { element in element.path.map { (element.name, $0) } },
                               uniquingKeysWith: { first, _ in first })

        let baseElements = Set(base?.elements.map(\.name) ?? [])
        let headElements = Set(head?.elements.map(\.name) ?? [])
        addedElements = headElements.subtracting(baseElements).sorted()
        removedElements = baseElements.subtracting(headElements).sorted()

        struct Ends: Hashable { var from: String, to: String }
        func ends(_ dependency: Dependency) -> Ends { Ends(from: dependency.from, to: dependency.to) }
        let baseDependencies = Set(base?.dependencies.map(ends) ?? [])
        let headDependencies = Set(head?.dependencies.map(ends) ?? [])
        addedDependencies = (head?.dependencies ?? []).filter { !baseDependencies.contains(ends($0)) }
        removedDependencies = (base?.dependencies ?? []).filter { !headDependencies.contains(ends($0)) }

        cyclicGroups = Self.groupChanges(base: base?.cyclicGroups ?? [], head: head?.cyclicGroups ?? [],
                                         isNew: { !baseDependencies.contains(ends($0)) })
    }

    /// Matches each head group with the base group it shares the most members with (at least two:
    /// a pair of elements that still depend on each other).
    static func groupChanges(base: [ModuleReport.CyclicGroup], head: [ModuleReport.CyclicGroup],
                             isNew: (Dependency) -> Bool) -> [CyclicGroupChange] {
        let baseSets = base.map { Set($0.members) }
        var matchedBase = Set<Int>()
        var changes: [CyclicGroupChange] = []

        for (headIndex, group) in head.enumerated() {
            let members = Set(group.members)
            var best: (index: Int, overlap: Int)?
            for (baseIndex, baseMembers) in baseSets.enumerated() {
                let overlap = baseMembers.intersection(members).count
                if overlap >= 2 {
                    matchedBase.insert(baseIndex)
                    if overlap > (best?.overlap ?? 0) { best = (baseIndex, overlap) }
                }
            }
            var joined = group.members
            var left: [String] = []
            if let best {
                joined = group.members.filter { !baseSets[best.index].contains($0) }
                left = base[best.index].members.filter { !members.contains($0) }
            }
            let kind: CyclicGroupChange.Kind
            switch (best == nil, joined.isEmpty, left.isEmpty) {
            case (true, _, _): kind = .new
            case (false, true, true): continue
            case (false, false, true): kind = .grown
            case (false, true, false): kind = .shrunk
            case (false, false, false): kind = .changed
            }
            var newDependencies: [NewDependency] = []
            if kind != .shrunk {
                let breaking = group.breakingDependencies
                newDependencies = group.dependencies.filter(isNew).map { dependency in
                    let split = breaking.first { $0.dependency.from == dependency.from && $0.dependency.to == dependency.to }
                    return NewDependency(dependency: dependency, remainingGroups: split?.remainingGroups)
                }
                // Splitting ones first, the most effective first (as in `breakingDependencies`).
                let order = Dictionary(breaking.enumerated().map { ("\($1.dependency.from)\u{0}\($1.dependency.to)", $0) },
                                       uniquingKeysWith: { first, _ in first })
                func rank(_ new: NewDependency) -> Int { order["\(new.dependency.from)\u{0}\(new.dependency.to)"] ?? Int.max }
                newDependencies = newDependencies.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            }
            changes.append(CyclicGroupChange(kind: kind, baseGroup: best.map { $0.index + 1 }, headGroup: headIndex + 1,
                                             baseSize: best.map { base[$0.index].size } ?? 0, headSize: group.size,
                                             members: group.members, joined: joined, left: left,
                                             newDependencies: newDependencies))
        }
        for (index, group) in base.enumerated() where !matchedBase.contains(index) {
            changes.append(CyclicGroupChange(kind: .resolved, baseGroup: index + 1, headGroup: nil,
                                             baseSize: group.size, headSize: 0, members: group.members,
                                             joined: [], left: group.members, newDependencies: []))
        }
        let order: [CyclicGroupChange.Kind: Int] = [.new: 0, .grown: 0, .changed: 0, .shrunk: 1, .resolved: 2]
        return changes.enumerated().sorted { first, second in
            let a = first.element, b = second.element
            return (order[a.kind]!, -max(a.headSize, a.baseSize), first.offset) < (order[b.kind]!, -max(b.headSize, b.baseSize), second.offset)
        }.map(\.element)
    }
}
