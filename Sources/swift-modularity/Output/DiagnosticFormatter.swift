import Foundation

// MARK: - Diagnostic Output

/// Formats the dependencies inside cyclic groups as compiler-style warnings at the reference that
/// creates each dependency: Xcode (`--format xcode`) and GitHub Actions annotations
/// (`--format github`).
///
/// Only file-level modules produce warnings, since only they have source locations. Each
/// dependency between two members of the same cyclic group is one warning: removing it is one way
/// to break the cycle.
public enum DiagnosticFormatter {
    public enum Style: String, CaseIterable, Sendable {
        /// `path:line:column: warning: message`
        case xcode
        /// `::warning file=path,line=n,col=n,title=...::message`
        case github
    }

    /// - Parameter relativeTo: Annotated paths under this directory are written relative to it
    ///   (GitHub resolves them against the repository root); nil keeps them as they are.
    public static func format(_ report: ModularityReport, style: Style, relativeTo baseDirectory: String? = nil) -> String {
        var lines: [String] = []
        for module in report.modules where module.level == .file {
            let paths = Dictionary(module.elements.map { ($0.name, $0.path ?? $0.name) }, uniquingKeysWith: { first, _ in first })
            for (index, group) in module.cyclicGroups.enumerated() {
                for dependency in group.dependencies {
                    let path = displayPath(paths[dependency.from] ?? dependency.from, relativeTo: baseDirectory)
                    let line = dependency.line ?? 1
                    let column = dependency.column ?? 1
                    let message = message(for: dependency, group: group, number: index + 1, module: module)
                    switch style {
                    case .xcode:
                        lines.append("\(path):\(line):\(column): warning: \(message)")
                    case .github:
                        let properties = [
                            "file=\(escapeProperty(path))",
                            "line=\(line)",
                            "col=\(column)",
                            "title=\(escapeProperty("Dependency cycle (swift-modularity)"))",
                        ]
                        lines.append("::warning \(properties.joined(separator: ","))::\(escapeData(message))")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "`Parser` (Parser.swift) depends back on this file: cyclic group 1 of 8 files in Core, the
    /// Core (26.7% of the module) [swift-modularity]"
    static func message(for dependency: ModuleReport.Dependency, group: ModuleReport.CyclicGroup, number: Int, module: ModuleReport) -> String {
        let symbol = dependency.symbol.map { "`\($0)` " } ?? ""
        var text = "\(symbol)(\(dependency.to)) depends back on this file, directly or indirectly: "
        text += "cyclic group \(number) of \(group.size) files in \(module.name)"
        if group.isCore {
            text += ", the Core (\(TextFormatter.percent(module.largestCyclicGroupRatio)) of the module)"
        }
        return text + " [swift-modularity]"
    }

    static func displayPath(_ path: String, relativeTo baseDirectory: String?) -> String {
        FileDependencyGraphBuilder.displayPath(path, relativeTo: baseDirectory)
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
