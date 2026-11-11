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
/// - a top-level function, variable or macro;
/// - a member (method, property, enum case, nested type) reached through implicit `self` inside a
///   type or one of its extensions, through `self.` or `Self.`, or through a type name
///   (`Parser.shared`). Members inherited from protocols and superclasses declared in the module
///   are found too.
///
/// `private` and `fileprivate` declarations are visible only in their own file. An extension
/// depends on the file that declares the extended type. Nothing is compiled or type-checked, so the
/// graph is an approximation, with known limits:
///
/// - Members reached through a value (`value.helper()`) or an implicit member expression
///   (`.helper`) are not resolved: that needs the type of the value. A key path is resolved up to
///   its first member (`\Model.name`); without its root (`\.name`), only when one extension of a
///   type of another module, or else one type of the module, has a member of that name.
/// - Names are matched by text. Parameters, generic parameters and what a body declares (local
///   variables, functions and types) shadow other names. Overloads of a member are told apart by
///   their argument labels only, and those of a top-level function not at all, so a name declared
///   alike in several files depends on all of them.
/// - Declarations and references inside `#if` blocks count whatever the condition.
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
            return ParsedFile(path: path, source: source)
        }
        let readable = parsed.compactMap { $0 }
        let unreadable = zip(files, parsed).filter { $0.1 == nil }.map(\.0)

        let symbols = SymbolTable(readable.map(\.declarations))
        let edges = await readable.enumerated().map { ($0, $1) }.concurrentMap { index, file in
            file.references(symbols: symbols, index: index)
        }
        let nodes = readable.map { file in
            DependencyGraph.Node(name: Self.displayPath(file.path, relativeTo: baseDirectory), path: file.path)
        }
        return Result(graph: DependencyGraph(nodes: nodes, edges: edges.flatMap { $0 }), unreadableFiles: unreadable)
    }

    /// Builds the graph of in-memory sources, for tests. Node names are the keys.
    public func build(sources: [(name: String, source: String)]) -> DependencyGraph {
        let parsed = sources.map { ParsedFile(path: $0.name, source: $0.source) }
        let symbols = SymbolTable(parsed.map(\.declarations))
        let edges = parsed.enumerated().flatMap { index, file in file.references(symbols: symbols, index: index) }
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

    init(path: String, source: String) {
        self.path = path
        tree = Parser.parse(source: source)
        let collector = DeclarationCollector(viewMode: .sourceAccurate)
        collector.walk(tree)
        declarations = collector.declarations
    }

    func references(symbols: SymbolTable, index: Int) -> [DependencyGraph.Edge] {
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = ReferenceCollector(symbols: symbols, own: declarations, file: index, converter: converter)
        collector.walk(tree)
        return collector.edges
    }
}

// MARK: - Declarations

/// What one file declares.
struct Declarations: Sendable {
    /// Qualified type names (`Outer.Inner`), file-private ones included.
    var types: Set<String> = []
    /// Top-level functions, variables and macros, file-private ones included.
    var values: Set<String> = []
    /// The subsets of `types` and `values` declared `private` or `fileprivate` (or inside such a
    /// type): other files cannot refer to them.
    var privateTypes: Set<String> = []
    var privateValues: Set<String> = []
    /// Members by qualified type name, including members declared in extensions.
    var members: [String: [Member]] = [:]
    /// Inheritance clauses of types and extensions.
    var inheritance: [Inheritance] = []

    struct Member: Sendable {
        var name: String
        var shape: MemberShape
        /// Whether other files can refer to it (not file-private).
        var isVisible: Bool
    }

    struct Inheritance: Sendable {
        /// The qualified name of the type (or the extended type).
        var type: String
        /// Where the clause is written, to resolve the names in it.
        var context: [String]
        /// The inherited names, as `["Outer", "Proto"]` for `Outer.Proto`.
        var inherited: [[String]]
    }
}

/// The declarations of every file of the module.
struct SymbolTable: Sendable {
    /// Files declaring each type or top-level value that other files can refer to.
    private(set) var types: [String: Set<Int>] = [:]
    private(set) var values: [String: Set<Int>] = [:]
    /// The declarations of each member, by type, then name.
    private(set) var members: [String: [String: [(file: Int, member: Declarations.Member)]]] = [:]
    /// The protocols and superclasses (declared in the module) of each type.
    private(set) var supertypes: [String: Set<String>] = [:]
    /// The types that declare a member of each name that other files can see.
    private var typesWithMember: [String: Set<String>] = [:]
    /// Every type declared in the module, file-private ones included.
    private var declaredTypes: Set<String> = []

    init(_ files: [Declarations]) {
        for (file, declarations) in files.enumerated() {
            declaredTypes.formUnion(declarations.types)
            for name in declarations.types.subtracting(declarations.privateTypes) {
                types[name, default: []].insert(file)
            }
            for name in declarations.values.subtracting(declarations.privateValues) {
                values[name, default: []].insert(file)
            }
            for (type, list) in declarations.members {
                for member in list {
                    members[type, default: [:]][member.name, default: []].append((file, member))
                    if member.isVisible { typesWithMember[member.name, default: []].insert(type) }
                }
            }
        }
        for declarations in files {
            for clause in declarations.inheritance {
                for inherited in clause.inherited {
                    if let name = resolveType(inherited, from: clause.context, own: declarations) {
                        supertypes[clause.type, default: []].insert(name)
                    }
                }
            }
        }
    }

    /// The qualified name of a type written as `components` in `context`: `Inner` inside `Outer`
    /// is `Outer.Inner` if that exists. Types of `own` (including file-private ones) come first.
    func resolveType(_ components: [String], from context: [String], own: Declarations) -> String? {
        for length in stride(from: context.count, through: 0, by: -1) {
            let name = (context.prefix(length) + components).joined(separator: ".")
            if own.types.contains(name) || types[name] != nil {
                return name
            }
        }
        return nil
    }

    /// The files declaring the members named `name` of `type` that fit `use`, or nil if `type`
    /// has no member named `name`.
    ///
    /// As in Swift's name lookup, the type itself (with its extensions) comes first, then its
    /// protocols and superclasses, level by level: the nearest level with a member that fits wins,
    /// so a type's own `title` hides the protocol requirement it implements. The set may be
    /// empty: a file-private member of another file is still a member, but not visible here.
    func member(_ name: String, of type: String, use: MemberUse) -> Set<Int>? {
        var visited: Set<String> = []
        var level = [type]
        var isMember = false
        while !level.isEmpty {
            var files: Set<Int> = []
            var fits = false
            for current in level where visited.insert(current).inserted {
                for (file, member) in members[current]?[name] ?? [] {
                    isMember = true
                    guard member.shape.fits(use) else { continue }
                    fits = true
                    if member.isVisible { files.insert(file) }
                }
            }
            if fits { return files }
            level = level.flatMap { supertypes[$0] ?? [] }.filter { !visited.contains($0) }
        }
        return isMember ? [] : nil
    }

    /// The type that a key path without its root (`\.name`) most likely starts from: the one
    /// extension of a type of another module with a visible member `name` (as `theme` in
    /// `extension EnvironmentValues`, which views also name their own `@Environment(\.theme) var
    /// theme`), else the one type of the module with that member; nil when it is ambiguous.
    func keyPathRoot(forMember name: String) -> String? {
        guard let types = typesWithMember[name] else { return nil }
        let extended = types.filter { !declaredTypes.contains($0) }
        let candidates = extended.isEmpty ? types : extended
        return candidates.count == 1 ? candidates.first : nil
    }
}

/// Collects the declarations of a file. Bodies of functions, accessors and initializers are
/// skipped: what they declare is local.
final class DeclarationCollector: SyntaxVisitor {
    private(set) var declarations = Declarations()
    /// Each enclosing type or extension: its qualified name and whether it is file-private.
    private var context: [(path: [String], isPrivate: Bool)] = []

    private var path: [String] { context.last?.path ?? [] }
    private var inPrivateScope: Bool { context.last?.isPrivate ?? false }

    private func declareMember(_ name: String, shape: MemberShape = .value, isPrivate: Bool) {
        let type = path.joined(separator: ".")
        declarations.members[type, default: []].append(.init(name: name, shape: shape, isVisible: !isPrivate && !inPrivateScope))
    }

    private func enterType(_ name: TokenSyntax, modifiers: DeclModifierListSyntax, inheritance: InheritanceClauseSyntax?) {
        let isPrivate = modifiers.isFilePrivate || inPrivateScope
        let qualified = path + [name.identifierText]
        let key = qualified.joined(separator: ".")
        declarations.types.insert(key)
        if isPrivate { declarations.privateTypes.insert(key) }
        if !path.isEmpty { declareMember(name.identifierText, shape: .type, isPrivate: isPrivate) }
        recordInheritance(of: key, clause: inheritance)
        context.append((qualified, isPrivate))
    }

    private func recordInheritance(of type: String, clause: InheritanceClauseSyntax?) {
        let inherited = clause?.inheritedTypes.compactMap { $0.type.qualifiedComponents } ?? []
        if !inherited.isEmpty {
            declarations.inheritance.append(.init(type: type, context: path, inherited: inherited))
        }
    }

    private func declareValue(_ name: String, shape: MemberShape = .value, modifiers: DeclModifierListSyntax) {
        if path.isEmpty {
            declarations.values.insert(name)
            if modifiers.isFilePrivate { declarations.privateValues.insert(name) }
        } else {
            declareMember(name, shape: shape, isPrivate: modifiers.isFilePrivate)
        }
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, modifiers: node.modifiers, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { context.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, modifiers: node.modifiers, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { context.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, modifiers: node.modifiers, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { context.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, modifiers: node.modifiers, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { context.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enterType(node.name, modifiers: node.modifiers, inheritance: node.inheritanceClause); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { context.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let extended = node.extendedType.qualifiedComponents else { return .skipChildren }
        recordInheritance(of: extended.joined(separator: "."), clause: node.inheritanceClause)
        // Members of a `private extension` are file-private.
        context.append((extended, node.modifiers.isFilePrivate))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) {
        if node.extendedType.qualifiedComponents != nil { context.removeLast() }
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let isPrivate = node.modifiers.isFilePrivate || inPrivateScope
        let key = (path + [node.name.identifierText]).joined(separator: ".")
        declarations.types.insert(key)
        if isPrivate { declarations.privateTypes.insert(key) }
        if !path.isEmpty { declareMember(node.name.identifierText, shape: .type, isPrivate: isPrivate) }
        return .skipChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        declareValue(node.name.identifierText, modifiers: node.modifiers); return .skipChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if case .identifier = node.name.tokenKind {
            let parameters = node.signature.parameterClause.parameters.map {
                MemberShape.Parameter(label: $0.firstName.argumentLabel, hasDefault: $0.defaultValue != nil || $0.ellipsis != nil)
            }
            declareValue(node.name.identifierText, shape: .function(parameters), modifiers: node.modifiers)
        }
        return .skipChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        declareValue(node.name.identifierText, modifiers: node.modifiers); return .skipChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            for name in binding.pattern.boundNames {
                declareValue(name, modifiers: node.modifiers)
            }
        }
        return .skipChildren
    }

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            // A case with associated values is called like a function: `.failure(error)`.
            let shape = element.parameterClause.map { clause in
                MemberShape.enumCase(clause.parameters.map {
                    MemberShape.Parameter(label: $0.firstName?.argumentLabel, hasDefault: $0.defaultValue != nil)
                })
            } ?? .value
            declareValue(element.name.identifierText, shape: shape, modifiers: node.modifiers)
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
    private let own: Declarations
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

    init(symbols: SymbolTable, own: Declarations, file: Int, converter: SourceLocationConverter) {
        self.symbols = symbols
        self.own = own
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

    /// The enclosing type of which `name` is a member (innermost first), with the files declaring
    /// the member, or nil if it is not a member of an enclosing type.
    private func enclosingMember(_ name: String, use: MemberUse) -> (type: String, files: Set<Int>)? {
        let path = self.path
        for length in stride(from: path.count, through: 1, by: -1) {
            let type = path.prefix(length).joined(separator: ".")
            if let files = symbols.member(name, of: type, use: use) {
                return (type, files)
            }
        }
        return nil
    }

    /// The qualified name of a type written as `components` here, and the files declaring it
    /// (none when this file declares it).
    private func resolveType(_ components: [String]) -> (name: String, files: Set<Int>)? {
        guard let name = symbols.resolveType(components, from: path, own: own) else { return nil }
        return (name, own.types.contains(name) ? [] : symbols.types[name] ?? [])
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

    // MARK: Types and extensions

    private func enterType(_ name: TokenSyntax, generics: GenericParameterClauseSyntax?) {
        declareLocal(name)
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
        context.append(extended ?? path)
        scopes.append([])
        for child in [Syntax(node.attributes), node.inheritanceClause.map(Syntax.init), node.genericWhereClause.map(Syntax.init), Syntax(node.memberBlock)].compactMap({ $0 }) {
            walk(child)
        }
        context.removeLast()
        scopes.removeLast()
        return .skipChildren
    }

    /// Attributes whose arguments are names of other kinds, not references to declarations.
    private static let opaqueAttributes: Set<String> = ["_spi", "_spi_available", "objc", "_silgen_name", "_cdecl", "_originallyDefinedIn", "_documentation"]

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.attributeName.as(IdentifierTypeSyntax.self)?.name.text, Self.opaqueAttributes.contains(name) {
            return .skipChildren
        }
        return .visitChildren
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

    /// A name declared inside a body (a variable, a function, a type) is local from here on in
    /// the enclosing scope: it is not a declaration of the module, and it shadows those.
    private func declareLocal(_ name: TokenSyntax) {
        if bodyDepth > 0, !scopes.isEmpty {
            scopes[scopes.count - 1].insert(name.identifierText)
        }
    }

    private static func parameterNames(_ clause: FunctionParameterClauseSyntax) -> [String] {
        clause.parameters.map { ($0.secondName ?? $0.firstName).identifierText }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        declareLocal(node.name)
        let generics = node.genericParameterClause?.parameters.map { $0.name.identifierText } ?? []
        enterBody(generics + Self.parameterNames(node.signature.parameterClause))
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { exitBody() }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        declareLocal(node.name); return .visitChildren
    }

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
        declareLocal(node.identifier)
        return .skipChildren
    }

    /// `if let x {` and `guard let x else` without an initializer bind `x` as well.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if node.initializer == nil, bodyDepth > 0, !scopes.isEmpty,
           let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.identifierText {
            scopes[scopes.count - 1].insert(name)
        }
        return .visitChildren
    }

    // MARK: References

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        if case .identifier = node.name.tokenKind {
            let name = node.name.identifierText
            if !isLocal(name), let type = resolveType([name]) {
                record(type.files, symbol: name, at: node)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // `Outer.Inner`: the base is visited as an identifier type; this adds the nested type.
        if let components = TypeSyntax(node).qualifiedComponents, !isLocal(components[0]) {
            for length in stride(from: components.count, through: 2, by: -1) {
                if let type = resolveType(Array(components.prefix(length))) {
                    record(type.files, symbol: type.name, at: node)
                    break
                }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let memberName = node.declName.baseName.identifierText

        // `self.member`, `Self.member`, also at the start of a chain (`self.member.other`).
        if let base = node.base?.as(DeclReferenceExprSyntax.self),
           base.baseName.tokenKind == .keyword(.self) || base.baseName.tokenKind == .keyword(.Self) {
            if !path.isEmpty, let files = symbols.member(memberName, of: path.joined(separator: "."), use: MemberUse(ExprSyntax(node))) {
                record(files, symbol: "\(path.last!).\(memberName)", at: node)
            }
            return .visitChildren
        }
        // Only the outermost access of a chain: `A.b.c` is handled once, as a whole.
        if let parent = node.parent?.as(MemberAccessExprSyntax.self), parent.base?.id == node.id {
            return .visitChildren
        }

        // `Type.member`, `Outer.Inner.member`, `Outer.Inner()`: the longest prefix that is a type,
        // then the member after it.
        guard let base = node.base, let baseComponents = base.qualifiedComponents,
              !isLocal(baseComponents[0]), enclosingMember(baseComponents[0], use: .value) == nil else {
            return .visitChildren
        }
        let components = baseComponents + [memberName]
        for length in stride(from: components.count, through: 1, by: -1) {
            guard let type = resolveType(Array(components.prefix(length))) else { continue }
            if length >= 2 {
                record(type.files, symbol: type.name, at: node)
            }
            let use = length == components.count - 1 ? MemberUse(ExprSyntax(node)) : .value
            if length < components.count, let files = symbols.member(components[length], of: type.name, use: use) {
                record(files, symbol: "\(type.name).\(components[length])", at: node)
            }
            break
        }
        return .visitChildren
    }

    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        // The first property of a key path is a member of its root: `\Model.name`, or `\.name`
        // with the root inferred. Later components are members of types not known here.
        guard let first = node.components.first, first.period != nil,
              case .property(let property) = first.component,
              case .identifier = property.declName.baseName.tokenKind else {
            return .visitChildren
        }
        let name = property.declName.baseName.identifierText
        if let root = node.root {
            // A generic parameter or local type as the root shadows the module's types.
            if let components = root.qualifiedComponents, !isLocal(components[0]),
               let type = resolveType(components), let files = symbols.member(name, of: type.name, use: .value) {
                record(files, symbol: "\(type.name.split(separator: ".").last!).\(name)", at: property)
            }
        } else if let type = symbols.keyPathRoot(forMember: name), let files = symbols.member(name, of: type, use: .value) {
            // Without the type of the root, only a name that is not ambiguous is resolved:
            // `\.id` could be any identifiable type's.
            record(files, symbol: "\(type.split(separator: ".").last!).\(name)", at: property)
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard case .identifier = node.baseName.tokenKind else { return .visitChildren }
        // `value.name`: handled with the member access, if at all.
        if let access = node.parent?.as(MemberAccessExprSyntax.self), access.declName.id == node.id {
            return .visitChildren
        }
        // `\Root.name.other`: members of the key path's root and of what follows, not names in
        // scope here (see the key path).
        if node.parent?.is(KeyPathPropertyComponentSyntax.self) == true {
            return .visitChildren
        }
        let name = node.baseName.identifierText
        guard !isLocal(name) else { return .visitChildren }
        // A member of an enclosing type (implicit `self`) shadows top-level names.
        if let member = enclosingMember(name, use: MemberUse(ExprSyntax(node))) {
            record(member.files, symbol: "\(member.type.split(separator: ".").last!).\(name)", at: node)
            return .visitChildren
        }
        if let type = resolveType([name]) {
            record(type.files, symbol: name, at: node)
        } else if !own.values.contains(name), let files = symbols.values[name] {
            record(files, symbol: name, at: node)
        }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        recordMacro(node.macroName, at: node)
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        recordMacro(node.macroName, at: node)
        return .visitChildren
    }

    private func recordMacro(_ name: TokenSyntax, at node: some SyntaxProtocol) {
        let text = name.identifierText
        if !own.values.contains(text), let files = symbols.values[text] {
            record(files, symbol: "#" + text, at: node)
        }
    }
}

// MARK: - Overloads

/// What a member declaration accepts, to tell overloads apart by their argument labels.
enum MemberShape: Sendable {
    struct Parameter: Sendable {
        /// The argument label; nil for `_`.
        var label: String?
        /// Whether a call may leave the argument out (default value or variadic).
        var hasDefault: Bool
    }

    /// A property, a case without associated values or an associated type.
    case value
    /// A nested type or typealias: used as a value, called as an initializer, or as a type.
    case type
    case function([Parameter])
    case enumCase([Parameter])

    func fits(_ use: MemberUse) -> Bool {
        switch (self, use) {
        case (.type, _):
            return true
        case (.value, .value):
            return true
        case (.value, .call(let labels, _)):
            // Calling a property of function type: closures take no argument labels.
            return labels.allSatisfy { $0 == nil }
        case (.function, .value):
            // An unapplied method reference (`map(transform)`) is rare; a property is likelier.
            return false
        case (.enumCase, .value):
            return true
        case (.function(let parameters), .call(let labels, let trailingClosures)),
             (.enumCase(let parameters), .call(let labels, let trailingClosures)):
            return Self.match(parameters[...], labels[...], trailingClosures: trailingClosures)
        }
    }

    /// Whether the arguments can be assigned to the parameters in order, leaving out only
    /// parameters with defaults. Trailing closures may take any of the remaining parameters.
    private static func match(_ parameters: ArraySlice<Parameter>, _ labels: ArraySlice<String?>, trailingClosures: Int) -> Bool {
        guard let parameter = parameters.first else { return labels.isEmpty && trailingClosures == 0 }
        if let label = labels.first, label == parameter.label,
           match(parameters.dropFirst(), labels.dropFirst(), trailingClosures: trailingClosures) {
            return true
        }
        if labels.isEmpty, trailingClosures > 0,
           match(parameters.dropFirst(), labels, trailingClosures: trailingClosures - 1) {
            return true
        }
        return parameter.hasDefault && match(parameters.dropFirst(), labels, trailingClosures: trailingClosures)
    }
}

/// How a member is used where it is referenced.
enum MemberUse: Sendable {
    case value
    /// Called with these argument labels (nil for unlabeled) and trailing closures.
    case call([String?], trailingClosures: Int)

    init(_ expression: ExprSyntax) {
        if let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id {
            self = .call(call.arguments.map { $0.label?.identifierText },
                         trailingClosures: (call.trailingClosure == nil ? 0 : 1) + call.additionalTrailingClosures.count)
        } else if let names = expression.as(DeclReferenceExprSyntax.self)?.argumentNames
                    ?? expression.as(MemberAccessExprSyntax.self)?.declName.argumentNames {
            // A compound name such as `parse(_:into:)`.
            self = .call(names.arguments.map { $0.name.tokenKind == .wildcard ? nil : $0.name.identifierText }, trailingClosures: 0)
        } else {
            self = .value
        }
    }
}

// MARK: - Helpers

extension DeclModifierListSyntax {
    /// `private` or `fileprivate` (but not `private(set)`, which only restricts writes).
    var isFilePrivate: Bool {
        contains { modifier in
            modifier.detail == nil
                && (modifier.name.tokenKind == .keyword(.private) || modifier.name.tokenKind == .keyword(.fileprivate))
        }
    }
}

extension TokenSyntax {
    /// The argument label of a parameter's first name: nil for `_`.
    var argumentLabel: String? {
        tokenKind == .wildcard ? nil : identifierText
    }

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
