import Foundation
import Testing
@testable import swift_modularity

@Suite struct PathResolverTests {
    @Test func relativePathsAreResolvedAgainstTheDirectory() {
        #expect(PathResolver.resolve("Sources/../Lib", against: "/repo/App") == "/repo/App/Lib")
        #expect(PathResolver.resolve(".", against: "/repo/App") == "/repo/App")
    }

    @Test func absolutePathsAreKept() {
        #expect(PathResolver.resolve("/other/Sources", against: "/repo/App") == "/other/Sources")
    }

    /// In `diff`, a revision may lack the current directory: it must still be the base, not its
    /// parent.
    @Test func aMissingDirectoryIsStillTheBase() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("PathResolverTests-\(UUID().uuidString)/New").path
        #expect(PathResolver.resolve("Sources", against: missing) == URL(fileURLWithPath: missing).standardizedFileURL.path + "/Sources")
    }
}
