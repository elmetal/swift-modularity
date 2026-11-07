import Testing
@testable import swift_modularity

@Suite struct FileDependencyGraphBuilderTests {
    /// The dependencies of a set of sources, as "from → to" strings.
    func dependencies(_ sources: [(String, String)]) -> Set<String> {
        let graph = FileDependencyGraphBuilder().build(sources: sources.map { (name: $0.0, source: $0.1) })
        return Set(graph.edges.map { "\(graph.nodes[$0.from].name) → \(graph.nodes[$0.to].name)" })
    }

    @Test func typeReferences() {
        let result = dependencies([
            ("Model.swift", "struct Model { var id: Int }"),
            ("Store.swift", "final class Store { var models: [Model] = [] }"),
            ("View.swift", "struct View { let store: Store }"),
        ])
        #expect(result == ["Store.swift → Model.swift", "View.swift → Store.swift"])
    }

    @Test func referenceLocationAndCount() {
        let graph = FileDependencyGraphBuilder().build(sources: [
            (name: "A.swift", source: "struct A {}"),
            (name: "B.swift", source: "import Foundation\n\nstruct B {\n    var a: A\n    func make() -> A { A() }\n}"),
        ])
        let edge = try! #require(graph.edge(from: 1, to: 0))
        #expect(edge.reference == .init(symbol: "A", line: 4, column: 12))
        #expect(edge.referenceCount == 3)
    }

    @Test func expressionsInheritanceAndAttributes() {
        let result = dependencies([
            ("Base.swift", "class Base {}"),
            ("Proto.swift", "protocol Proto {}"),
            ("Wrapper.swift", "@propertyWrapper struct Clamped { var wrappedValue: Int }"),
            ("Factory.swift", "enum Factory { static func make() -> Int { 0 } }"),
            ("Sub.swift", """
                class Sub: Base, Proto {
                    @Clamped var value: Int
                    func run() { _ = Factory.make() }
                }
                """),
        ])
        #expect(result == ["Sub.swift → Base.swift", "Sub.swift → Proto.swift", "Sub.swift → Wrapper.swift", "Sub.swift → Factory.swift"])
    }

    @Test func extensionsDependOnTheExtendedType() {
        let result = dependencies([
            ("Model.swift", "struct Model {}"),
            ("Model+Codable.swift", "extension Model: Codable {}"),
        ])
        #expect(result == ["Model+Codable.swift → Model.swift"])
    }

    @Test func topLevelFunctionsVariablesAndMacros() {
        let result = dependencies([
            ("Log.swift", "func log(_ message: String) {}\nlet defaultLevel = 1\n@freestanding(expression) macro stringify(_ value: Int) -> String = #externalMacro(module: \"M\", type: \"S\")"),
            ("Use.swift", "func use() { log(\"x\"); _ = defaultLevel; _ = #stringify(1) }"),
        ])
        #expect(result == ["Use.swift → Log.swift"])
    }

    @Test func nestedTypes() {
        let result = dependencies([
            ("Outer.swift", "struct Outer {}"),
            ("Outer+Inner.swift", "extension Outer { struct Inner {} }"),
            ("Qualified.swift", "struct Qualified { var inner: Outer.Inner }"),
            ("Unqualified.swift", "extension Outer { func make() -> Inner { Inner() } }"),
            ("Expression.swift", "func build() { _ = Outer.Inner() }"),
        ])
        #expect(result == [
            "Outer+Inner.swift → Outer.swift",
            "Qualified.swift → Outer.swift", "Qualified.swift → Outer+Inner.swift",
            "Unqualified.swift → Outer.swift", "Unqualified.swift → Outer+Inner.swift",
            "Expression.swift → Outer.swift", "Expression.swift → Outer+Inner.swift",
        ])
    }

    @Test func nestedNamesDoNotMatchTopLevelReferences() {
        // `Options` is only nested in `Parser`; `Options` elsewhere is not it.
        let result = dependencies([
            ("Parser.swift", "struct Parser { struct Options {} }"),
            ("Other.swift", "struct Other { var options: Options }"),
        ])
        #expect(result.isEmpty)
    }

    @Test func localsParametersGenericsAndMembersShadowTopLevelNames() {
        let result = dependencies([
            ("Globals.swift", "let value = 1\nfunc helper() {}\nstruct T {}\nlet item = 2\nlet error = 3"),
            ("Shadowing.swift", """
                struct Box<T> {
                    var contents: T
                    func helper() {}
                    func run(value: Int) {
                        _ = value
                        helper()
                        for item in [1] { _ = item }
                        do { try work() } catch { _ = error }
                    }
                    func work() throws {}
                }
                """),
        ])
        #expect(result.isEmpty)
    }

    @Test func membersAccessedThroughValuesAreNotResolved() {
        // `helper` is added by an extension in another file, but members are not resolved.
        let result = dependencies([
            ("Model.swift", "struct Model {}"),
            ("Helper.swift", "extension Model { func helper() {} }"),
            ("Use.swift", "func use(model: Model) { model.helper() }"),
        ])
        #expect(result == ["Helper.swift → Model.swift", "Use.swift → Model.swift"])
    }

    @Test func cycleBetweenFiles() {
        let graph = FileDependencyGraphBuilder().build(sources: [
            (name: "A.swift", source: "struct A { var b: B? }"),
            (name: "B.swift", source: "struct B { var c: C? }"),
            (name: "C.swift", source: "struct C { var a: A? }"),
            (name: "D.swift", source: "struct D { var a: A }"),
        ])
        let analysis = ModularityAnalysis(graph: graph)
        #expect(analysis.cyclicGroups.map { $0.map { graph.nodes[$0].name } } == [["A.swift", "B.swift", "C.swift"]])
        #expect(analysis.architecture == .corePeriphery)
        #expect(analysis.groups == [.core, .core, .core, .control])
    }

    @Test func escapedIdentifiers() {
        let result = dependencies([
            ("Default.swift", "enum `default` {}"),
            ("Use.swift", "struct Use { var value: `default` }"),
        ])
        #expect(result == ["Use.swift → Default.swift"])
    }
}
