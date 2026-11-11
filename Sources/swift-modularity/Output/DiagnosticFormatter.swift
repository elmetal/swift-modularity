import Foundation

// MARK: - Diagnostic Output

/// Formats the most effective dependency to remove in each cyclic group as a note at the reference
/// that creates it: Xcode (`--format xcode`) and GitHub Actions (`--format github`).
///
/// These are notes, not warnings: a cyclic group is not an error, and the note only says where a
/// change would split it. For each group, only the dependencies with the largest reduction are
/// reported (several when they tie). Only file-level modules have source locations.
public enum DiagnosticFormatter {
    public enum Style: String, CaseIterable, Sendable {
        /// `path:line:column: note: message`
        case xcode
        /// `::notice file=path,line=n,col=n,title=...::message`
        case github
    }

    /// - Parameter relativeTo: Annotated paths under this directory are written relative to it
    ///   (GitHub resolves them against the repository root); nil keeps them as they are.
    public static func format(_ report: ModularityReport, style: Style, relativeTo baseDirectory: String? = nil) -> String {
        var lines: [String] = []
        for module in report.modules where module.level == .file {
            let paths = Dictionary(module.elements.map { ($0.name, $0.path ?? $0.name) }, uniquingKeysWith: { first, _ in first })
            for (index, group) in module.cyclicGroups.enumerated() {
                guard let best = group.breakingDependencies.first?.reduction else { continue }
                for breaking in group.breakingDependencies where breaking.reduction == best {
                    let dependency = breaking.dependency
                    let path = FileDependencyGraphBuilder.displayPath(paths[dependency.from] ?? dependency.from, relativeTo: baseDirectory)
                    let text = message(for: breaking, group: group, number: index + 1, module: module)
                    lines.append(note(text, title: "Dependency that splits a cycle (swift-modularity)", path: path,
                                      at: dependency, style: style))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One note at the first reference of `dependency` in the file at `path`.
    static func note(_ text: String, title: String, path: String, at dependency: ModuleReport.Dependency, style: Style) -> String {
        let line = dependency.line ?? 1
        let column = dependency.column ?? 1
        switch style {
        case .xcode:
            return "\(path):\(line):\(column): note: \(text)"
        case .github:
            let properties = [
                "file=\(escapeProperty(path))",
                "line=\(line)",
                "col=\(column)",
                "title=\(escapeProperty(title))",
            ]
            return "::notice \(properties.joined(separator: ","))::\(escapeData(text))"
        }
    }

    /// "removing the dependency on Parser.swift (`Parser`, 3 references) splits cyclic group 1 of
    /// 12 files in App: largest group left 9 files (9 + 2) [swift-modularity]"
    static func message(for breaking: ModuleReport.BreakingDependencyReport, group: ModuleReport.CyclicGroup, number: Int, module: ModuleReport) -> String {
        let dependency = breaking.dependency
        var text = "removing the dependency on \(dependency.to) ("
        if let symbol = dependency.symbol { text += "`\(symbol)`, " }
        text += "\(dependency.references) reference\(dependency.references == 1 ? "" : "s")) splits cyclic group \(number) of \(group.size) files in \(module.name)"
        if group.isCore { text += " (the Core)" }
        return text + ": " + TextFormatter.remaining(breaking.remainingGroups, noun: "files") + " [swift-modularity]"
    }

    static func escapeData(_ text: String) -> String {
        text.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    static func escapeProperty(_ text: String) -> String {
        escapeData(text)
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }
}
