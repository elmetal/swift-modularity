import Foundation

// MARK: - File Reading Utilities

/// Provides file reading utilities for Swift source files.
public class FileReader {

    /// Finds all Swift files in a directory.
    /// - Parameters:
    ///   - directory: The directory path to search
    ///   - exclude: Patterns for files and directories to skip, matched against paths relative to `directory`
    /// - Returns: Swift file paths, sorted so that results are reproducible
    /// - Throws: An error if `directory` is not an existing directory, or file system errors
    public static func findSwiftFiles(in directory: String, excluding exclude: [ExcludePattern] = []) throws -> [String] {
        let url = URL(fileURLWithPath: directory)
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "FileReaderError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not a directory: \(directory)"])
        }

        // Hidden files and directories (including `.build` and `.git`) are skipped.
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(domain: "FileReaderError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create file enumerator"])
        }

        var swiftFiles: [String] = []

        while let element = enumerator.nextObject() {
            guard let fileURL = element as? URL else { continue }

            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            // DocC catalogs hold tutorial snippets, which are not compiled with the module.
            if resourceValues.isDirectory == true && fileURL.pathExtension == "docc" {
                enumerator.skipDescendants()
                continue
            }
            // The enumerator's depth gives the path relative to `directory`, even when the URLs it
            // returns resolve symbolic links in the root (such as /var → /private/var).
            let relative = Array(fileURL.pathComponents.suffix(enumerator.level))
            if !exclude.isEmpty {
                if exclude.anyMatches(pathComponents: relative) {
                    if resourceValues.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }
            if resourceValues.isRegularFile == true && fileURL.pathExtension == "swift" {
                // Spelled under `directory` as given, so that paths can be named relative to it.
                swiftFiles.append(relative.reduce(url) { $0.appendingPathComponent($1) }.path)
            }
        }

        return swiftFiles.sorted()
    }

    /// Finds all Swift files in a list of directories and Swift files.
    ///
    /// Directories are searched recursively, and exclude patterns are matched against paths relative
    /// to each directory, so a directory named here is always searched even if its own name matches.
    /// A file named here is skipped if its path, as given, matches a pattern.
    /// - Parameters:
    ///   - paths: Directories and `.swift` files
    ///   - exclude: Patterns for files and directories to skip
    /// - Returns: Swift file paths without duplicates, sorted so that results are reproducible
    /// - Throws: An error if a path does not exist or is a file without the `.swift` extension
    public static func findSwiftFiles(in paths: [String], excluding exclude: [ExcludePattern] = []) throws -> [String] {
        var files = Set<String>()
        for path in paths {
            try validateInputPath(path)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                for file in try findSwiftFiles(in: path, excluding: exclude) {
                    files.insert(URL(fileURLWithPath: file).standardizedFileURL.path)
                }
            } else if !exclude.anyMatches(pathComponents: path.split(separator: "/").map(String.init)) {
                files.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        return files.sorted()
    }

    /// Checks that a path is an existing directory or `.swift` file.
    /// - Throws: An error describing the problem otherwise
    public static func validateInputPath(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw NSError(domain: "FileReaderError", code: 3, userInfo: [NSLocalizedDescriptionKey: "'\(path)' does not exist."])
        }
        guard isDirectory.boolValue || URL(fileURLWithPath: path).pathExtension == "swift" else {
            throw NSError(domain: "FileReaderError", code: 4, userInfo: [NSLocalizedDescriptionKey: "'\(path)' is neither a directory nor a .swift file."])
        }
    }
}
