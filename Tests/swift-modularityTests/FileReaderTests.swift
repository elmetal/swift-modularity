import Foundation
import Testing
@testable import swift_modularity

@Suite struct FileReaderTests {
    @Test func docCCatalogsAreSkipped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("Module.docc/Resources")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "struct A {}".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "struct Step {}".write(to: docs.appendingPathComponent("Tutorial.step1.swift"), atomically: true, encoding: .utf8)
        let files = try FileReader.findSwiftFiles(in: root.path)
        #expect(files.map { URL(fileURLWithPath: $0).lastPathComponent } == ["A.swift"])
    }

    @Test func pathsAreSpelledUnderTheGivenDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real/Package/Sub")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "struct A {}".write(to: real.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        // A symbolic link in the path of the directory given, like /var → /private/var on macOS.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("real"))
        let directory = link.appendingPathComponent("Package").path
        let files = try FileReader.findSwiftFiles(in: directory)
        #expect(files == [directory + "/Sub/A.swift"])
    }
}
