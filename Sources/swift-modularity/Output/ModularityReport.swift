// MARK: - Report

/// The results of analyzing one or more modules: what the JSON output contains.
public struct ModularityReport: Sendable, Codable, Equatable {
    /// The version of the JSON output of every command (`files`, `package` and `diff`). It is
    /// raised when a field is removed or renamed, or changes meaning or type; adding a field
    /// does not raise it.
    public static let currentSchemaVersion = 1

    /// The `currentSchemaVersion` of the tool that wrote the report.
    public var schemaVersion: Int
    public var modules: [ModuleReport]

    public init(modules: [ModuleReport]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.modules = modules
    }
}

/// The analysis of one dependency graph: the targets of a package, or the files of one module.
public struct ModuleReport: Sendable, Codable, Equatable {
    public enum Level: String, Sendable, Codable {
        /// The elements are the targets of a package.
        case target
        /// The elements are the Swift files of one module.
        case file
    }

    public struct Element: Sendable, Codable, Equatable {
        public var name: String
        public var path: String?
        /// VFI: elements that depend on this one directly or indirectly, including itself.
        public var fanIn: Int
        /// VFO: elements this one depends on directly or indirectly, including itself.
        public var fanOut: Int
        public var group: ComponentGroup
        /// The 1-based number of the element's cyclic group in `cyclicGroups`, if any.
        public var cyclicGroup: Int?
    }

    public struct Dependency: Sendable, Codable, Equatable {
        public var from: String
        public var to: String
        /// The first reference (file level only).
        public var symbol: String?
        public var line: Int?
        public var column: Int?
        public var references: Int
    }

    public struct CyclicGroup: Sendable, Codable, Equatable {
        public var size: Int
        /// Whether this group is the Core of a core-periphery (or borderline) architecture.
        public var isCore: Bool
        public var members: [String]
        /// The dependencies between members of the group.
        public var dependencies: [Dependency]
        /// The dependencies whose removal splits the group, the most effective first.
        public var breakingDependencies: [BreakingDependencyReport]
    }

    /// A dependency whose removal splits its cyclic group (see `CycleBreaking`).
    public struct BreakingDependencyReport: Sendable, Codable, Equatable {
        public var dependency: Dependency
        /// The sizes of the cyclic groups left without the dependency, largest first.
        public var remainingGroups: [Int]
        /// How many files leave the largest group.
        public var reduction: Int
    }

    /// A directory and whether it could become a target of its own (see `Extraction`).
    public struct ExtractionCandidateReport: Sendable, Codable, Equatable {
        public var directory: String
        public var files: [String]
        /// No file of the directory depends on a file outside it.
        public var canBeLowerTarget: Bool
        /// No file outside depends on a file of the directory.
        public var canBeUpperTarget: Bool
        /// Dependencies from the directory to the rest of the module.
        public var outgoing: [Dependency]
        /// Dependencies from the rest of the module to the directory.
        public var incoming: [Dependency]
        /// Files outside the directory that its files depend on, directly or indirectly.
        public var requiredFiles: [String]
    }

    public var name: String
    public var level: Level
    public var directory: String?
    public var elementCount: Int
    public var dependencyCount: Int
    public var propagationCost: Double
    public var architecture: ArchitectureType
    public var view: PartitionView
    /// False when no element depends on another: every element's `group` is then `central`,
    /// which tells nothing about it (see `ModularityAnalysis.isPartitioned`).
    public var isPartitioned: Bool
    public var largestCyclicGroupSize: Int
    public var largestCyclicGroupRatio: Double
    public var medianFanIn: Double
    public var medianFanOut: Double
    public var thresholds: ArchitectureThresholds
    public var cyclicGroups: [CyclicGroup]
    /// The elements in the order of the reordered DSM.
    public var elements: [Element]
    public var dependencies: [Dependency]
    /// Directories that could become targets (file level only), as ordered by `Extraction`.
    public var extractionCandidates: [ExtractionCandidateReport]
    /// Files that could not be read (file level only).
    public var unreadableFiles: [String]

    public init(name: String, level: Level, directory: String?, analysis: ModularityAnalysis, unreadableFiles: [String] = []) {
        let graph = analysis.graph
        func dependency(_ edge: DependencyGraph.Edge) -> Dependency {
            Dependency(from: graph.nodes[edge.from].name, to: graph.nodes[edge.to].name,
                       symbol: edge.reference?.symbol, line: edge.reference?.line, column: edge.reference?.column,
                       references: edge.referenceCount)
        }
        let hasCore = analysis.view == .corePeriphery
        self.name = name
        self.level = level
        self.directory = directory
        self.elementCount = graph.count
        self.dependencyCount = graph.edges.count
        self.propagationCost = analysis.propagationCost
        self.architecture = analysis.architecture
        self.view = analysis.view
        self.isPartitioned = analysis.isPartitioned
        self.largestCyclicGroupSize = analysis.largestCyclicGroupSize
        self.largestCyclicGroupRatio = analysis.largestCyclicGroupRatio
        self.medianFanIn = analysis.medianFanIn
        self.medianFanOut = analysis.medianFanOut
        self.thresholds = analysis.thresholds
        self.cyclicGroups = analysis.cyclicGroups.enumerated().map { index, members in
            let memberSet = Set(members)
            let edges = members.flatMap { member in
                graph.successors[member].filter(memberSet.contains).compactMap { graph.edge(from: member, to: $0) }
            }
            let breaking = CycleBreaking.breakingDependencies(in: graph, group: members).map {
                BreakingDependencyReport(dependency: dependency($0.edge), remainingGroups: $0.remainingGroupSizes, reduction: $0.reduction)
            }
            return CyclicGroup(size: members.count, isCore: hasCore && index == 0,
                               members: members.map { graph.nodes[$0].name },
                               dependencies: edges.map(dependency), breakingDependencies: breaking)
        }
        self.elements = analysis.dsmOrder.map { index in
            Element(name: graph.nodes[index].name, path: graph.nodes[index].path,
                    fanIn: analysis.visibility.fanIn[index], fanOut: analysis.visibility.fanOut[index],
                    group: analysis.groups[index], cyclicGroup: analysis.cyclicGroupIndex(of: index).map { $0 + 1 })
        }
        self.dependencies = graph.edges.map(dependency)
        self.extractionCandidates = level == .file ? Extraction.directoryCandidates(in: analysis).map { candidate in
            ExtractionCandidateReport(directory: candidate.directory,
                                      files: candidate.files.map { graph.nodes[$0].name },
                                      canBeLowerTarget: candidate.canBeLowerTarget,
                                      canBeUpperTarget: candidate.canBeUpperTarget,
                                      outgoing: candidate.outgoing.map(dependency),
                                      incoming: candidate.incoming.map(dependency),
                                      requiredFiles: candidate.requiredFiles.map { graph.nodes[$0].name })
        } : []
        self.unreadableFiles = unreadableFiles
    }

    /// A short name for the elements: "files" or "targets".
    public var elementNoun: String { level == .file ? "files" : "targets" }
}
