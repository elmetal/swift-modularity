import Foundation

/// Resolves paths given on the command line.
public enum PathResolver {
    /// The standardized absolute path of `path`, relative paths taken from `directory`.
    ///
    /// `directory` need not exist: in `diff`, a revision may lack the current directory.
    /// (Without `isDirectory`, Foundation takes a path that does not exist for a file, and a
    /// relative path would replace its last component.)
    public static func resolve(_ path: String, against directory: String) -> String {
        URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true))
            .standardizedFileURL.path
    }
}
