import ArgumentParser
import Foundation
import IndexStoreDB
import swift_modularity

/// Compares swift-modularity's file dependency graph with the dependencies in a compiler index
/// store. See PROTOCOL.md.
@main
struct GraphAccuracy: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graph-accuracy",
        abstract: "Compare swift-modularity's file graph with the compiler's index."
    )

    @Option(help: "The index store (.build/<triple>/debug/index/store, or DerivedData/.../Index.noindex/DataStore).")
    var store: String

    @Option(name: .customLong("root"), help: "Directories whose Swift files are evaluated (repeatable). Files are grouped into modules by the index.")
    var roots: [String]

    @Option(help: "A name for this corpus entry in the results.")
    var label: String

    @Option(help: "Skip directories and files matching a glob pattern (repeatable).")
    var exclude: [String] = []

    @Option(help: "Write detailed results (JSON) to this file.")
    var output: String?

    @Option(help: "libIndexStore.dylib.")
    var libIndexStore = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"

    func run() throws {
        let library = try IndexStoreLibrary(dylibPath: libIndexStore)
        let databasePath = NSTemporaryDirectory() + "graph-accuracy-\(UUID().uuidString)"
        let db = try IndexStoreDB(storePath: store, databasePath: databasePath, library: library,
                                  waitUntilDoneInitializing: true, listenToUnitEvents: false)
        db.pollForUnitChangesAndWait(isInitialScan: true)
        defer { try? FileManager.default.removeItem(atPath: databasePath) }

        let files = try FileReader.findSwiftFiles(in: roots, excluding: exclude.map(ExcludePattern.init)).map(realPath)
        var modules: [String: [String]] = [:]
        var unindexed: [String] = []
        var stale: Set<String> = []
        var occurrencesByFile: [String: [SymbolOccurrence]] = [:]
        for file in files {
            let occurrences = db.symbolOccurrences(inFilePath: file)
            guard let module = occurrences.first?.location.moduleName else {
                unindexed.append(file)
                continue
            }
            occurrencesByFile[file] = occurrences
            modules[module, default: []].append(file)
            if let modified = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date,
               let unit = db.dateOfLatestUnitFor(filePath: file), unit < modified {
                stale.insert(module)
            }
        }

        var definitions: [String: [String]] = [:]
        func definitionFiles(of usr: String) -> [String] {
            if let cached = definitions[usr] { return cached }
            let paths = Array(Set(db.occurrences(ofUSR: usr, roles: .definition).map { realPath($0.location.path) }))
            definitions[usr] = paths
            return paths
        }

        var results: [ModuleResult] = []
        var skipped: [String: String] = [:]
        for (module, moduleFiles) in modules.sorted(by: { $0.key < $1.key }) {
            if stale.contains(module) { skipped[module] = "stale index"; continue }
            if moduleFiles.count < 2 { skipped[module] = "fewer than 2 files"; continue }
            let sortedFiles = moduleFiles.sorted()
            let fileSet = Set(sortedFiles)
            let base = commonDirectory(sortedFiles)

            // Ground truth from the index.
            var truth: [Pair: TruthEdge] = [:]
            for file in sortedFiles {
                for occurrence in occurrencesByFile[file] ?? [] {
                    let roles = occurrence.roles
                    guard roles.contains(.reference),
                          !roles.contains(.implicit), !roles.contains(.definition), !roles.contains(.declaration) else { continue }
                    for target in definitionFiles(of: occurrence.symbol.usr) where target != file && fileSet.contains(target) {
                        let pair = Pair(from: file, to: target)
                        let kind = Category(occurrence.symbol.kind)
                        let reference = "\(occurrence.symbol.name) [\(occurrence.symbol.kind)] line \(occurrence.location.line)"
                        if var edge = truth[pair] {
                            if kind.inScope, !edge.inScope { edge.inScope = true; edge.scopeReference = reference }
                            edge.count += 1
                            truth[pair] = edge
                        } else {
                            truth[pair] = TruthEdge(inScope: kind.inScope, firstReference: reference,
                                                    scopeReference: kind.inScope ? reference : nil, count: 1)
                        }
                    }
                }
            }

            // The tool's graph.
            let builder = FileDependencyGraphBuilder()
            let toolGraph = builder.build(sources: sortedFiles.map { (name: $0, source: (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "") })
            var tool: [Pair: String] = [:]
            for edge in toolGraph.edges {
                let reference = edge.reference.map { "\($0.symbol) line \($0.line)" } ?? "?"
                tool[Pair(from: toolGraph.nodes[edge.from].name, to: toolGraph.nodes[edge.to].name)] = reference
            }

            let truthAll = Set(truth.keys)
            let truthScope = Set(truth.filter { $0.value.inScope }.keys)
            let toolEdges = Set(tool.keys)

            // Structure on the same nodes.
            let index = Dictionary(uniqueKeysWithValues: sortedFiles.enumerated().map { ($1, $0) })
            let nodes = sortedFiles.map { DependencyGraph.Node(name: relative($0, to: base), path: $0) }
            func graph(_ edges: Set<Pair>) -> DependencyGraph {
                DependencyGraph(nodes: nodes, edges: edges.map { DependencyGraph.Edge(from: index[$0.from]!, to: index[$0.to]!) })
            }
            let toolGraph2 = graph(toolEdges)
            let truthGraph = graph(truthAll)
            let toolAnalysis = ModularityAnalysis(graph: toolGraph2)
            let truthAnalysis = ModularityAnalysis(graph: truthGraph)
            let breaking = BreakingEvaluation(tool: toolAnalysis, truth: truthAnalysis, names: nodes.map(\.name))

            results.append(ModuleResult(
                module: module,
                files: sortedFiles.count,
                toolEdges: toolEdges.count,
                truthEdges: truthAll.count,
                truthScopeEdges: truthScope.count,
                truePositives: toolEdges.intersection(truthAll).count,
                truePositivesInScope: toolEdges.intersection(truthScope).count,
                tool: StructureSummary(toolAnalysis),
                truth: StructureSummary(truthAnalysis),
                coMembership: PairAgreement(tool: toolAnalysis, truth: truthAnalysis),
                coreJaccard: coreJaccard(toolAnalysis, truthAnalysis),
                groupAgreement: Double(zip(toolAnalysis.groups, truthAnalysis.groups).filter { $0 == $1 }.count) / Double(sortedFiles.count),
                breaking: breaking,
                falsePositives: toolEdges.subtracting(truthAll).sorted().map {
                    ErrorEdge(from: relative($0.from, to: base), to: relative($0.to, to: base), reference: tool[$0]!)
                },
                falseNegativesInScope: truthScope.subtracting(toolEdges).sorted().map {
                    ErrorEdge(from: relative($0.from, to: base), to: relative($0.to, to: base), reference: truth[$0]!.scopeReference ?? "")
                },
                falseNegativesOutOfScope: truthAll.subtracting(truthScope).subtracting(toolEdges).sorted().map {
                    ErrorEdge(from: relative($0.from, to: base), to: relative($0.to, to: base), reference: truth[$0]!.firstReference)
                }
            ))
        }

        let report = CorpusResult(label: label, store: store, modules: results, skipped: skipped, unindexedFiles: unindexed.count, unindexedPaths: unindexed)
        if let output {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        }
        print(report.table())
    }
}

// MARK: - Model

struct Pair: Hashable, Comparable {
    var from: String
    var to: String
    static func < (a: Pair, b: Pair) -> Bool { (a.from, a.to) < (b.from, b.to) }
}

struct TruthEdge {
    var inScope: Bool
    var firstReference: String
    var scopeReference: String?
    var count: Int
}

/// Symbol kinds the tool claims to resolve (PROTOCOL.md, T_scope).
enum Category {
    case type, global, macro, member

    init(_ kind: IndexSymbolKind) {
        switch kind {
        case .struct, .class, .enum, .protocol, .typealias: self = .type
        case .function, .variable: self = .global
        case .macro: self = .macro
        default: self = .member
        }
    }

    var inScope: Bool { self != .member }
}

struct StructureSummary: Codable {
    var propagationCost: Double
    var largestCyclicGroup: Int
    var cyclicGroups: Int
    var architecture: String

    init(_ analysis: ModularityAnalysis) {
        propagationCost = analysis.propagationCost
        largestCyclicGroup = analysis.largestCyclicGroupSize
        cyclicGroups = analysis.cyclicGroups.count
        architecture = analysis.architecture.rawValue
    }
}

/// Pairs of files in the same cyclic group.
struct PairAgreement: Codable {
    var toolPairs: Int
    var truthPairs: Int
    var commonPairs: Int

    init(tool: ModularityAnalysis, truth: ModularityAnalysis) {
        func pairs(_ analysis: ModularityAnalysis) -> Set<[Int]> {
            Set(analysis.cyclicGroups.flatMap { group in
                group.flatMap { a in group.filter { a < $0 }.map { [a, $0] } }
            })
        }
        let toolSet = pairs(tool)
        let truthSet = pairs(truth)
        toolPairs = toolSet.count
        truthPairs = truthSet.count
        commonPairs = toolSet.intersection(truthSet).count
    }
}

struct ErrorEdge: Codable {
    var from: String
    var to: String
    var reference: String
}

struct ModuleResult: Codable {
    var module: String
    var files: Int
    var toolEdges: Int
    var truthEdges: Int
    var truthScopeEdges: Int
    var truePositives: Int
    var truePositivesInScope: Int
    var tool: StructureSummary
    var truth: StructureSummary
    var coMembership: PairAgreement
    /// Jaccard index of the largest cyclic groups (nil when neither has one).
    var coreJaccard: Double?
    var groupAgreement: Double
    var breaking: BreakingEvaluation
    var falsePositives: [ErrorEdge]
    var falseNegativesInScope: [ErrorEdge]
    var falseNegativesOutOfScope: [ErrorEdge]
}

struct CorpusResult: Codable {
    var label: String
    var store: String
    var modules: [ModuleResult]
    var skipped: [String: String]
    var unindexedFiles: Int
    var unindexedPaths: [String]

    func table() -> String {
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "   -  " : String(format: "%5.1f%%", Double(n) / Double(d) * 100) }
        var lines = ["\(label)"]
        lines.append("module".padding(toLength: 34, withPad: " ", startingAt: 0)
                     + " files  tool truth scope   prec  recAll recScope | PC tool/truth   core tool/truth  pairs P/R")
        for m in modules {
            let structure = String(format: "%5.1f%%/%5.1f%%", m.tool.propagationCost * 100, m.truth.propagationCost * 100)
            let core = "\(m.tool.largestCyclicGroup)/\(m.truth.largestCyclicGroup)".padding(toLength: 9, withPad: " ", startingAt: 0)
            let pairs = "\(pct(m.coMembership.commonPairs, m.coMembership.toolPairs))/\(pct(m.coMembership.commonPairs, m.coMembership.truthPairs))"
            lines.append(m.module.padding(toLength: 34, withPad: " ", startingAt: 0)
                         + String(format: " %5d %5d %5d %5d ", m.files, m.toolEdges, m.truthEdges, m.truthScopeEdges)
                         + "\(pct(m.truePositives, m.toolEdges)) \(pct(m.truePositives, m.truthEdges)) \(pct(m.truePositivesInScope, m.truthScopeEdges))  | \(structure)  \(core)        \(pairs)")
        }
        let tool = modules.map(\.toolEdges).reduce(0, +)
        let truth = modules.map(\.truthEdges).reduce(0, +)
        let scope = modules.map(\.truthScopeEdges).reduce(0, +)
        let tp = modules.map(\.truePositives).reduce(0, +)
        let tpScope = modules.map(\.truePositivesInScope).reduce(0, +)
        lines.append("pooled: precision \(pct(tp, tool)), recall (all) \(pct(tp, truth)), recall (scope) \(pct(tpScope, scope)); \(tool) tool edges, \(truth) index edges")
        var all = BreakingCounts(), top = BreakingCounts(); var indexBreaking = 0, indexFound = 0
        for m in modules {
            for (keyPath, counts) in [(\BreakingEvaluation.all, m.breaking.all), (\BreakingEvaluation.top, m.breaking.top)] {
                var target = keyPath == \BreakingEvaluation.all ? all : top
                target.findings += counts.findings; target.confirmed += counts.confirmed; target.sameEffect += counts.sameEffect
                target.noSplit += counts.noSplit; target.notInIndexCycle += counts.notInIndexCycle
                if keyPath == \BreakingEvaluation.all { all = target } else { top = target }
            }
            indexBreaking += m.breaking.indexBreaking; indexFound += m.breaking.indexBreakingFound
        }
        lines.append("splitting dependencies: \(all.findings) findings, confirmed \(pct(all.confirmed, all.findings)), same effect \(pct(all.sameEffect, all.findings)), no split \(all.noSplit), not in an index cycle \(all.notInIndexCycle); top \(top.findings): confirmed \(pct(top.confirmed, top.findings)), same effect \(pct(top.sameEffect, top.findings)); recall \(pct(indexFound, indexBreaking)) of \(indexBreaking)")
        if !skipped.isEmpty {
            lines.append("skipped: " + skipped.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
        }
        if unindexedFiles > 0 { lines.append("files not in the index: \(unindexedFiles)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Dependencies that split a cyclic group (PROTOCOL.md, addendum)

struct BreakingCounts: Codable {
    var findings = 0
    var confirmed = 0
    var sameEffect = 0
    var noSplit = 0
    var notInIndexCycle = 0
}

struct BreakingEvaluation: Codable {
    var all = BreakingCounts()
    var top = BreakingCounts()
    /// Dependencies that split a group of the index graph, and how many the tool reports.
    var indexBreaking = 0
    var indexBreakingFound = 0
    /// Findings that are not confirmed, for error analysis.
    var unconfirmed: [String] = []

    init(tool: ModularityAnalysis, truth: ModularityAnalysis, names: [String]) {
        var toolFindings: Set<[Int]> = []
        for group in tool.cyclicGroups {
            let findings = CycleBreaking.breakingDependencies(in: tool.graph, group: group)
            let best = findings.first?.reduction
            for finding in findings {
                let from = finding.edge.from, to = finding.edge.to
                toolFindings.insert([from, to])
                let outcome: (confirmed: Bool, same: Bool, noSplit: Bool)
                if truth.graph.edge(from: from, to: to) != nil,
                   let g = truth.cyclicGroupIndex(of: from), g == truth.cyclicGroupIndex(of: to) {
                    let truthGroup = truth.cyclicGroups[g]
                    let remaining = CycleBreaking.remainingGroupSizes(in: truth.graph, group: truthGroup, removing: from, to)
                    let splits = (remaining.first ?? 0) < truthGroup.count
                    outcome = (splits, splits && remaining == finding.remainingGroupSizes, !splits)
                    if !splits { unconfirmed.append("no split: \(names[from]) → \(names[to]) (index group \(truthGroup.count), tool group \(group.count))") }
                } else {
                    outcome = (false, false, false)
                    unconfirmed.append("not in an index cycle: \(names[from]) → \(names[to])")
                }
                for isTop in [false, true] where !isTop || finding.reduction == best {
                    var counts = isTop ? top : all
                    counts.findings += 1
                    if outcome.confirmed { counts.confirmed += 1 }
                    if outcome.same { counts.sameEffect += 1 }
                    if outcome.noSplit { counts.noSplit += 1 }
                    if !outcome.confirmed && !outcome.noSplit { counts.notInIndexCycle += 1 }
                    if isTop { top = counts } else { all = counts }
                }
            }
        }
        for group in truth.cyclicGroups {
            for finding in CycleBreaking.breakingDependencies(in: truth.graph, group: group) {
                indexBreaking += 1
                if toolFindings.contains([finding.edge.from, finding.edge.to]) { indexBreakingFound += 1 }
            }
        }
    }
}

// MARK: - Helpers

func realPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}

func commonDirectory(_ paths: [String]) -> String {
    guard var prefix = paths.first.map({ URL(fileURLWithPath: $0).deletingLastPathComponent().pathComponents }) else { return "/" }
    for path in paths.dropFirst() {
        let components = URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents
        prefix = Array(zip(prefix, components).prefix { $0 == $1 }.map(\.0))
    }
    return NSString.path(withComponents: prefix)
}

func relative(_ path: String, to base: String) -> String {
    FileDependencyGraphBuilder.displayPath(path, relativeTo: base)
}

func coreJaccard(_ tool: ModularityAnalysis, _ truth: ModularityAnalysis) -> Double? {
    let a = Set(tool.cyclicGroups.first ?? [])
    let b = Set(truth.cyclicGroups.first ?? [])
    guard !a.isEmpty || !b.isEmpty else { return nil }
    return Double(a.intersection(b).count) / Double(a.union(b).count)
}
