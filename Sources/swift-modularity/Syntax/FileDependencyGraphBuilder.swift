import Foundation
import SwiftParser
import SwiftSyntax

// MARK: - File Dependency Graph

/// Builds the dependency graph between the Swift files of one module from their syntax alone.
///
/// File A depends on file B when A refers to a name declared in B:
///
/// - a type (struct, class, enum, actor, protocol, typealias), including a nested type written
///   with its qualified name (`Outer.Inner`) or by its simple name inside the type or one of its
///   extensions;
/// - a top-level function, variable or macro.
///
/// An extension depends on the file that declares the extended type. Nothing is compiled or
/// type-checked, so the graph is an approximation, with known limits:
///
/// - Members are not resolved: calling a method that an extension in another file adds
///   (`value.helper()`) does not create a dependency on that file. Member access through a
///   type name (`Parser.default`) depends on the file that declares the type.
/// - Names are matched by text. Local variables, parameters, generic parameters and members of
///   the enclosing types shadow top-level names; members inherited from superclasses or
///   protocols do not.
/// - Declarations inside `#if` blocks count whatever the condition.
/// - A name declared in several files (overloaded top-level functions) depends on all of them.
public struct FileDependencyGraphBuilder: Sendable {
    public init() {}

    /// The result: the graph (one node per file, named by its path relative to `relativeTo`) and
    /// the files that could not be read.
    public struct Result: Sendable {
        public var graph: DependencyGraph
        public var unreadableFiles: [String]
    }

    /// Builds the graph of the given Swift files.
    /// - Parameters:
    ///   - files: The files of the module, as absolute or relative paths.
    ///   - baseDirectory: Node names are paths relative to this directory when they are inside it.
    public func build(files: [String], relativeTo baseDirectory: String? = nil) async -> Result {
        let parsed = await files.concurrentMap { path -> ParsedFile? in
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let tree = Parser.parse(source: source)
            let collector = DeclarationCollector(viewMode: .sourceAccurate)
            collector.walk(tree)
            return ParsedFile(path: path, tree: tree, declarations: collector.declarations)
        }
        let readable = parsed.compactMap { $0 }
        let unreadable = zip(files, parsed).filter { $0.1 == nil }.map(\.0)

        var symbols = SymbolTable()
        for (index, file) in readable.enumerated() {
            symbols.add(file.declarations, file: index)
        }

        let table = symbols
        let edges = await readable.enumerated().map { ($0, $1) }.concurrentMap { index, file -> [DependencyGraph.Edge] in
            let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
            let collector = ReferenceCollector(symbols: table, file: index, converter: converter)
            collector.walk(file.tree)
            return collector.edges
        }

        let nodes = readable.map { file in
            DependencyGraph.Node(name: Self.displayPath(file.path, relativeTo: baseDirectory), path: file.path)
        }
        return Result(graph: DependencyGraph(nodes: nodes, edges: edges.flatMap { $0 }), unreadableFiles: unreadable)
    }

    /// Builds the graph of in-memory sources, for tests. Node names are the keys.
    public func build(sources: [(name: String, source: String)]) -> DependencyGraph {
        let parsed = sources.map { name, source -> ParsedFile in
            let tree = Parser.parse(source: source)
            let collector = DeclarationCollector(viewMode: .sourceAccurate)
            collector.walk(tree)
            return ParsedFile(path: name, tree: tree, declarations: collector.declarations)
        }
        var symbols = SymbolTable()
        for (index, file) in parsed.enumerated() {
            symbols.add(file.declarations, file: index)
        }
        var edges: [DependencyGraph.Edge] = []
        for (index, file) in parsed.enumerated() {
            let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
            let collector = ReferenceCollector(symbols: symbols, file: index, converter: converter)
            collector.walk(file.tree)
            edges += collector.edges
        }
        return DependencyGraph(nodes: parsed.map { DependencyGraph.Node(name: $0.path, path: $0.path) }, edges: edges)
    }

    /// `path` relative to `baseDirectory` when it is inside it, otherwise `path`.
    public static func displayPath(_ path: String, relativeTo baseDirectory: String?) -> String {
        guard let baseDirectory else { return path }
        let base = baseDirectory.hasSuffix("/") ? baseDirectory : baseDirectory + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

private struct ParsedFile: @unchecked Sendable {
    // `SourceFileSyntax` is immutable; it is only read after parsing.
    var path: String
    var tree: SourceFileSyntax
    var declarations: Declarations
}

// MARK: - Declarations

/// What one file declares.
struct Declarations: Sendable {
    /// Qualified type names (`Outer.Inner`).
    var types: Set<String> = []
    /// Top-level functions, variables and macros.
    var values: Set<String> = []
    /// Member names (methods, properties, enum cases, associated types) by qualified type name,
    /// including members declared in extensions.
    var members: [String: Set<String>] = [:]
}

struct SymbolTable: Sendable {
    var types: [String: Set<Int>] = [:]
    var values: [String: Set<Int>] = [:]
    var members: [String: Set<String>] = [:]

    mutating func add(_ declarations: Declarations, file: Int) {
        for name in declarations.types {
            types[name, default: []].insert(file)
        }
        for name in declarations.values {
            values[name, default: []].insert(file)
        }
        for (type, names) in declarations.members {
            members[type, default: []].formUnion(names)
        }
    }
}

/// Collects the declarations of a file. Bodies of functions, accessors and initializers are
/// skipped: what they declare is local.
final class DeclarationCollector: SyntaxVisitor {
    private(set) var declarations = Declarations()
    /// The qualified name of each enclosing type or extension.
    private var context: [[String]] = []

    private var path: [String] { context.last ?? [] }

    private func declareType(_ name: TokenSyntax) -> [String] {
        let qualified = path + [name.identifierText]
        declarations.types.insert(qualified.joined(separator: "."))
        if !path.isEmpty {
            declarations.members[path.joined(separator: "."), default: []].insert(name.identifierText)
        }
        return qualified
    }

    private func declareValue(_ name: String) {
        if path.isEmpty {
            declarations.values.insert(name)
        } else {
            declarations.members[path.joined(separator: "."), default: []].insert(name)
        }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        context.append(declareType(node.name)); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { context.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        context.append(declareType(node.name)); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { context.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        context.append(declareType(node.name)); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { context.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        context.append(declareType(node.name)); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { context.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        context.append(declareType(node.name)); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { context.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let extended = node.extendedType.qualifiedComponents else { return .skipChildren }
        context.append(extended); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        if node.extendedType.qualifiedComponents != nil { context.removeLast() }
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = declareType(node.name); return .skipChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        declareValue(node.name.identifierText); return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if case .identifier = node.name.tokenKind {
            declareValue(node.name.identifierText)
        }
        return .skipChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        declareValue(node.name.identifierText); return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            for name in binding.pattern.boundNames {
                declareValue(name)
            }
        }
        return .skipChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            declareValue(element.name.identifierText)
        }
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    // Top-level statements in `main.swift` and scripts.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}

// MARK: - References

/// Collects the dependencies of one file on the other files.
final class ReferenceCollector: SyntaxVisitor {
    private let symbols: SymbolTable
    private let file: Int
    private let converter: SourceLocationConverter
    /// The first reference to each file, and the number of references.
    private var found: [Int: (reference: DependencyGraph.Reference, count: Int)] = [:]
    /// The qualified name of each enclosing type or extension.
    private var context: [[String]] = []
    /// Names bound by enclosing declarations: parameters, generic parameters, local variables.
    private var scopes: [Set<String>] = []
    /// How many function-like bodies enclose the current node (where patterns bind locals).
    private var bodyDepth = 0

    init(symbols: SymbolTable, file: Int, converter: SourceLocationConverter) {
        self.symbols = symbols
        self.file = file
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    var edges: [DependencyGraph.Edge] {
        found.map { target, value in
            DependencyGraph.Edge(from: file, to: target, reference: value.reference, referenceCount: value.count)
        }
    }

    // MARK: Resolution

    private var path: [String] { context.last ?? [] }

    private func isLocal(_ name: String) -> Bool {
        scopes.contains { $0.contains(name) }
    }

    /// Whether `name` is a member of an enclosing type (so an unqualified use refers to it).
    private func isMemberOfEnclosingType(_ name: String) -> Bool {
        let path = self.path
        guard !path.isEmpty else { return false }
        for length in stride(from: path.count, through: 1, by: -1) {
            if symbols.members[path.prefix(length).joined(separator: "."), default: []].contains(name) {
                return true
            }
        }
        return false
    }

    /// The files declaring a type written as `components` here: `Inner` inside `Outer` is
    /// `Outer.Inner` if that exists.
    private func resolveType(_ components: [String]) -> Set<Int>? {
        let path = self.path
        for length in stride(from: path.count, through: 0, by: -1) {
            let name = (path.prefix(length) + components).joined(separator: ".")
            if let files = symbols.types[name] {
                return files
            }
        }
        return nil
    }

    private func record(_ files: Set<Int>, symbol: String, at node: some SyntaxProtocol) {
        for target in files where target != file {
            if let existing = found[target] {
                found[target] = (existing.reference, existing.count + 1)
            } else {
                let location = converter.location(for: node.positionAfterSkippingLeadingTrivia)
                found[target] = (DependencyGraph.Reference(symbol: symbol, line: location.line, column: location.column), 1)
            }
        }
    }

    private func referenceType(named name: String, at node: some SyntaxProtocol) {
        guard !isLocal(name), let files = resolveType([name]) else { return }
        record(files, symbol: name, at: node)
    }

    // MARK: Types and extensions

    private func enterType(_ name: TokenSyntax, generics: GenericParameterClauseSyntax?) {
        context.append(path + [name.identifierText])
        scopes.append(Set(generics?.parameters.map { $0.name.identifierText } ?? []))
    }

    private func exitType() {
        context.removeLast()
        scopes.removeLast()
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, generics: node.genericParameterClause); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { exitType() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, generics: node.genericParameterClause); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { exitType() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, generics: node.genericParameterClause); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { exitType() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, generics: node.genericParameterClause); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { exitType() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, generics: nil); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { exitType() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // The extended type is resolved outside the extension's own context.
        walk(node.extendedType)
        let extended = node.extendedType.qualifiedComponents
        // `extension Inner` inside nothing refers to a top-level type; qualified names as written.
        context.append(extended ?? path)
        scopes.append([])
        for child in [Syntax(node.attributes), node.inheritanceClause.map(Syntax.init), node.genericWhereClause.map(Syntax.init), Syntax(node.memberBlock)].compactMap({ $0 }) {
            walk(child)
        }
        context.removeLast()
        scopes.removeLast()
        return .skipChildren
    }

    // MARK: Function-like scopes

    private func enterBody(_ names: [String]) {
        scopes.append(Set(names))
        bodyDepth += 1
    }

    private func exitBody() {
        scopes.removeLast()
        bodyDepth -= 1
    }

    private static func parameterNames(_ clause: FunctionParameterClauseSyntax) -> [String] {
        clause.parameters.map { ($0.secondName ?? $0.firstName).identifierText }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let generics = node.genericParameterClause?.parameters.map { $0.name.identifierText } ?? []
        enterBody(generics + Self.parameterNames(node.signature.parameterClause))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { exitBody() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let generics = node.genericParameterClause?.parameters.map { $0.name.identifierText } ?? []
        enterBody(generics + Self.parameterNames(node.signature.parameterClause))
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { exitBody() }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let generics = node.genericParameterClause?.parameters.map { $0.name.identifierText } ?? []
        enterBody(generics + Self.parameterNames(node.parameterClause))
        return .visitChildren
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { exitBody() }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        var names = ["newValue", "oldValue"]
        if let parameter = node.parameters?.name { names.append(parameter.identifierText) }
        enterBody(names)
        return .visitChildren
    }
    override func visitPost(_ node: AccessorDeclSyntax) { exitBody() }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        var names: [String] = []
        switch node.signature?.parameterClause {
        case .simpleInput(let parameters):
            names = parameters.map { $0.name.identifierText }
        case .parameterClause(let clause):
            names = clause.parameters.map { ($0.secondName ?? $0.firstName).identifierText }
        case nil:
            break
        }
        enterBody(names)
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { exitBody() }

    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        enterBody([]); return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) { exitBody() }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        // The implicit `error` of a catch clause without a pattern.
        if node.catchItems.isEmpty, !scopes.isEmpty { scopes[scopes.count - 1].insert("error") }
        return .visitChildren
    }

    /// Names bound by patterns inside bodies (`let x`, `if let x`, `for x in`, `case .a(let x)`)
    /// are local from here on in the enclosing scope.
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        if bodyDepth > 0, !scopes.isEmpty {
            scopes[scopes.count - 1].insert(node.identifier.identifierText)
        }
        return .skipChildren
    }

    /// `if let x {` and `guard let x else` without an initializer bind `x` as well.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if node.initializer == nil, bodyDepth > 0, !scopes.isEmpty,
           let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.identifierText {
            // The name refers to the outer variable, which is already local or a member.
            scopes[scopes.count - 1].insert(name)
        }
        return .visitChildren
    }

    // MARK: References

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if case .identifier = node.name.tokenKind {
            referenceType(named: node.name.identifierText, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // `Outer.Inner`: the base is visited as an identifier type; this adds the nested type.
        if let components = TypeSyntax(node).qualifiedComponents, !isLocal(components[0]) {
            resolvePrefix(components, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        // `Outer.Inner.make()`: a nested type used in an expression.
        if let components = ExprSyntax(node).qualifiedComponents, components.count >= 2, !isLocal(components[0]),
           !isMemberOfEnclosingType(components[0]) {
            resolvePrefix(components, at: node)
        }
        return .visitChildren
    }

    /// Records the longest prefix of two or more components that names a type.
    private func resolvePrefix(_ components: [String], at node: some SyntaxProtocol) {
        for length in stride(from: components.count, through: 2, by: -1) {
            let prefix = Array(components.prefix(length))
            if let files = resolveType(prefix) {
                record(files, symbol: prefix.joined(separator: "."), at: node)
                return
            }
        }
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard case .identifier = node.baseName.tokenKind else { return .visitChildren }
        // `value.name`: a member, not resolved.
        if let access = node.parent?.as(MemberAccessExprSyntax.self), access.declName.id == node.id {
            return .visitChildren
        }
        let name = node.baseName.identifierText
        guard !isLocal(name), !isMemberOfEnclosingType(name) else { return .visitChildren }
        if let files = resolveType([name]) {
            record(files, symbol: name, at: node)
        } else if let files = symbols.values[name] {
            record(files, symbol: name, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if let files = symbols.values[node.macroName.identifierText] {
            record(files, symbol: "#" + node.macroName.identifierText, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        if let files = symbols.values[node.macroName.identifierText] {
            record(files, symbol: "#" + node.macroName.identifierText, at: node)
        }
        return .visitChildren
    }
}

// MARK: - Helpers

extension TokenSyntax {
    /// The text of an identifier without the backticks of an escaped identifier.
    var identifierText: String {
        let text = self.text
        if text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

extension TypeSyntax {
    /// `A.B.C` as `["A", "B", "C"]`, for identifier and member types (generic arguments are
    /// ignored); nil for other types.
    var qualifiedComponents: [String]? {
        if let identifier = self.as(IdentifierTypeSyntax.self) {
            return [identifier.name.identifierText]
        }
        if let member = self.as(MemberTypeSyntax.self), let base = member.baseType.qualifiedComponents {
            return base + [member.name.identifierText]
        }
        return nil
    }
}

extension ExprSyntax {
    /// `a.b.c` as `["a", "b", "c"]` for chains of names; nil for other expressions.
    var qualifiedComponents: [String]? {
        if let reference = self.as(DeclReferenceExprSyntax.self), case .identifier = reference.baseName.tokenKind {
            return [reference.baseName.identifierText]
        }
        if let access = self.as(MemberAccessExprSyntax.self), let base = access.base?.qualifiedComponents {
            return base + [access.declName.baseName.identifierText]
        }
        return nil
    }
}

extension PatternSyntax {
    /// The names a pattern binds (`x`, `(a, b)`).
    var boundNames: [String] {
        if let identifier = self.as(IdentifierPatternSyntax.self) {
            return [identifier.identifier.identifierText]
        }
        if let tuple = self.as(TuplePatternSyntax.self) {
            return tuple.elements.flatMap { $0.pattern.boundNames }
        }
        return []
    }
}
