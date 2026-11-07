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
                    let line = dependency.line ?? 1
                    let column = dependency.column ?? 1
                    let text = message(for: breaking, group: group, number: index + 1, module: module)
                    switch style {
                    case .xcode:
                        lines.append("\(path):\(line):\(column): note: \(text)")
                    case .github:
                        let properties = [
                            "file=\(escapeProperty(path))",
                            "line=\(line)",
                            "col=\(column)",
                            "title=\(escapeProperty("Dependency that splits a cycle (swift-modularity)"))",
                        ]
                        lines.append("::notice \(properties.joined(separator: ","))::\(escapeData(text))")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "removing the dependency on Parser.swift (`Parser`, 3 references) splits cyclic group 1 of
    /// 12 files in App: largest group left 9 files (9 + 2) [swift-modularity]"
    static func message(for breaking: ModuleReport.BreakingDependencyReport, group: ModuleReport.CyclicGroup, number: Int, module: ModuleReport) -> String {
        let dependency = breaking.dependency
        var text = "removing the dependency on \(dependency.to) ("
        if let symbol = dependency.symbol { text += "`\(symbol)`, " }
        text += "\(dependency.references) reference\(dependency.references == 1 ? "" : "s")) splits cyclic group \(number) of \(group.size) files in \(module.name)"
        if group.isCore { text += " (the Core)" }
        if let largest = breaking.remainingGroups.first {
            text += ": largest group left \(largest) files"
            if breaking.remainingGroups.count > 1 {
                text += " (" + breaking.remainingGroups.map(String.init).joined(separator: " + ") + ")"
            }
        } else {
            text += ": no cycle left"
        }
        return text + " [swift-modularity]"
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
