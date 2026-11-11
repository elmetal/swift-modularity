import Foundation
import Testing
@testable import swift_modularity

@Suite struct RevisionRangeTests {
    @Test func defaultRange() throws {
        #expect(try RevisionRange.parse(nil) == RevisionRange(base: .defaultBranchMergeBase, head: .workingTree))
    }

    @Test func threeDots() throws {
        #expect(try RevisionRange.parse("main...feature") == RevisionRange(base: .mergeBase("main", "feature"), head: .revision("feature")))
        #expect(try RevisionRange.parse("main...") == RevisionRange(base: .mergeBase("main", "HEAD"), head: .revision("HEAD")))
    }

    @Test func twoDots() throws {
        #expect(try RevisionRange.parse("v1.0..v2.0") == RevisionRange(base: .revision("v1.0"), head: .revision("v2.0")))
        #expect(try RevisionRange.parse("..main") == RevisionRange(base: .revision("HEAD"), head: .revision("main")))
    }

    @Test func oneRevision() throws {
        #expect(try RevisionRange.parse("HEAD~3") == RevisionRange(base: .revision("HEAD~3"), head: .workingTree))
    }

    @Test func invalidRanges() {
        #expect(throws: RevisionRange.ParseError.self) { try RevisionRange.parse("") }
        #expect(throws: RevisionRange.ParseError.self) { try RevisionRange.parse("a...b..c") }
    }
}

@Suite struct ModularityDiffTests {
    func report(_ sources: [(name: String, source: String)]) -> ModularityReport {
        let graph = FileDependencyGraphBuilder().build(sources: sources)
        return ModularityReport(modules: [
            ModuleReport(name: "App", level: .file, directory: "App", analysis: ModularityAnalysis(graph: graph)),
        ])
    }

    func diff(_ base: [(name: String, source: String)], _ head: [(name: String, source: String)]) -> ModularityDiff {
        ModularityDiff(base: report(base), head: report(head),
                       baseSide: .init(name: "main", commit: "abc"), headSide: .init(name: "the working tree", commit: nil))
    }

    let acyclic: [(name: String, source: String)] = [
        ("A.swift", "struct A { var b: B? }"),
        ("B.swift", "struct B {}"),
        ("C.swift", "struct C { var a: A }"),
    ]
    /// B now refers to C: A → B → C → A.
    let cyclic: [(name: String, source: String)] = [
        ("A.swift", "struct A { var b: B? }"),
        ("B.swift", "struct B {\n    var c: C?\n}"),
        ("C.swift", "struct C { var a: A }"),
    ]

    @Test func noChange() {
        let module = diff(acyclic, acyclic).modules[0]
        #expect(module.isUnchanged)
        #expect(DiffTextFormatter().format(diff(acyclic, acyclic)).contains("App (files) — App: no change"))
    }

    @Test func newGroupAndTheDependencyThatClosesIt() throws {
        let module = diff(acyclic, cyclic).modules[0]
        #expect(module.addedDependencies.map { "\($0.from)→\($0.to)" } == ["B.swift→C.swift"])
        let change = try #require(module.cyclicGroups.first)
        #expect(change.kind == .new)
        #expect(change.headSize == 3)
        #expect(change.joined == change.members)
        #expect(change.newDependencies.count == 1)
        #expect(change.newDependencies[0].dependency.from == "B.swift")
        #expect(change.newDependencies[0].remainingGroups == [])
    }

    @Test func resolvedGroup() throws {
        let change = try #require(diff(cyclic, acyclic).modules[0].cyclicGroups.first)
        #expect(change.kind == .resolved)
        #expect(change.baseGroup == 1)
        #expect(change.headGroup == nil)
        #expect(change.newDependencies.isEmpty)
    }

    @Test func grownAndShrunkGroups() throws {
        let pair: [(name: String, source: String)] = [
            ("A.swift", "struct A { var b: B? }"),
            ("B.swift", "struct B { var a: A? }"),
            ("C.swift", "struct C {}"),
        ]
        let triple: [(name: String, source: String)] = [
            ("A.swift", "struct A { var b: B? }"),
            ("B.swift", "struct B { var a: A?; var c: C? }"),
            ("C.swift", "struct C { var a: A? }"),
        ]
        let grown = try #require(diff(pair, triple).modules[0].cyclicGroups.first)
        #expect(grown.kind == .grown)
        #expect((grown.baseSize, grown.headSize) == (2, 3))
        #expect(grown.joined == ["C.swift"])
        #expect(Set(grown.newDependencies.map(\.dependency.to)) == ["C.swift", "A.swift"])

        let shrunk = try #require(diff(triple, pair).modules[0].cyclicGroups.first)
        #expect(shrunk.kind == .shrunk)
        #expect(shrunk.left == ["C.swift"])
        #expect(shrunk.newDependencies.isEmpty)
    }

    @Test func addedAndRemovedModules() {
        let empty = ModularityReport(modules: [])
        let added = ModularityDiff(base: empty, head: report(acyclic), baseSide: .init(name: "main", commit: "abc"),
                                   headSide: .init(name: "HEAD", commit: "def"))
        #expect(added.modules.map(\.status) == [.added])
        let removed = ModularityDiff(base: report(acyclic), head: empty, baseSide: .init(name: "main", commit: "abc"),
                                     headSide: .init(name: "HEAD", commit: "def"))
        #expect(removed.modules.map(\.status) == [.removed])
        #expect(DiffTextFormatter().format(removed).contains("App (files) — App: removed"))
    }

    @Test func textOutput() {
        let text = DiffTextFormatter().format(diff(acyclic, cyclic))
        #expect(text.hasPrefix("Comparing main (abc) with the working tree"))
        #expect(text.contains("  Dependencies: 2 → 3 (+1, −0)"))
        #expect(text.contains("  Architecture: hierarchical → core-periphery"))
        #expect(text.contains("  Largest cyclic group: 0 → 3 files"))
        #expect(text.contains("    New: group 1, 3 files: A.swift, B.swift, C.swift"))
        #expect(text.contains("        B.swift → C.swift  `C` line 2 (1 reference): removing it splits the group, no cycle left"))
    }

    @Test func notesAtNewDependencies() {
        let output = DiagnosticFormatter.format(diff(acyclic, cyclic), style: .xcode)
        #expect(output == "B.swift:2:12: note: the new dependency on C.swift (`C`, 1 reference) closes cyclic group 1 of 3 files in App, which is new since main: removing it splits the group, no cycle left [swift-modularity]")
        #expect(DiagnosticFormatter.format(diff(cyclic, acyclic), style: .github).isEmpty)
    }

    @Test func jsonRoundTrips() throws {
        let value = diff(acyclic, cyclic)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(ModularityDiff.self, from: data) == value)
        #expect(String(decoding: data, as: UTF8.self).contains("\"schemaVersion\":1"))
    }
}

private let gitIsAvailable = (try? Git(directory: FileManager.default.currentDirectoryPath).run(["--version"])) != nil

@Suite(.enabled(if: gitIsAvailable)) struct GitTests {

    /// A repository with a commit on `main` and one on `feature`.
    func makeRepository() throws -> (git: Git, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = Git(directory: root.path)
        try git.run(["init", "--quiet", "--initial-branch=main"])
        try git.run(["config", "user.name", "Test"])
        try git.run(["config", "user.email", "test@example.com"])
        // `git commit` may start auto maintenance in the background, which would write
        // to `.git` while a test compares its contents.
        try git.run(["config", "maintenance.auto", "false"])
        try git.run(["config", "gc.auto", "0"])
        try "struct A {}\n".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try git.run(["add", "."])
        try git.run(["commit", "--quiet", "-m", "base"])
        try git.run(["switch", "--quiet", "-c", "feature"])
        try "struct B {}\n".write(to: root.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        try git.run(["add", "."])
        try git.run(["commit", "--quiet", "-m", "feature"])
        return (git, root)
    }

    @Test func resolvesTheDefaultBranchAndMergeBase() throws {
        let (git, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try git.defaultBranch() == "main")
        #expect(try git.mergeBase("main", "feature") == git.commit("main"))
        #expect(throws: Git.GitError.self) { try git.commit("no-such-branch") }
    }

    @Test func exportsARevisionWithoutWritingToTheRepository() throws {
        let (git, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let gitDirectory = root.appendingPathComponent(".git")
        let before = try FileManager.default.subpathsOfDirectory(atPath: gitDirectory.path).sorted()
        let index = try Data(contentsOf: gitDirectory.appendingPathComponent("index"))

        let export = try git.export(git.commit("main"))
        #expect(FileManager.default.fileExists(atPath: export.path + "/A.swift"))
        #expect(!FileManager.default.fileExists(atPath: export.path + "/B.swift"))
        let after = try FileManager.default.subpathsOfDirectory(atPath: gitDirectory.path).sorted()
        #expect(
            after == before,
            "added: \(Set(after).subtracting(before).sorted()), removed: \(Set(before).subtracting(after).sorted())"
        )
        #expect(try Data(contentsOf: gitDirectory.appendingPathComponent("index")) == index)
        export.remove()
        #expect(!FileManager.default.fileExists(atPath: export.path))
    }

    @Test func exportsTheWholeTreeFromASubdirectory() throws {
        let (git, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        // `diff` runs git in the current directory, and its paths may lead out of it (`../Other`).
        let subdirectory = root.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let export = try Git(directory: subdirectory.path).export(git.commit("feature"))
        defer { export.remove() }
        #expect(FileManager.default.fileExists(atPath: export.path + "/A.swift"))
        #expect(FileManager.default.fileExists(atPath: export.path + "/B.swift"))
    }
}
