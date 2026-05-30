@testable import CursorAPI
import XCTest

final class ResourceLookupTests: XCTestCase {
    func testFindsSwiftPMResourceBundleInsidePackagedAppResources() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorAPI.ResourceLookupTests.\(UUID().uuidString)", isDirectory: true)
        let resourcesDirectory = temporaryDirectory
            .appendingPathComponent("Contents/Resources/CursorAPI_CursorAPI.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        let expectedURL = resourcesDirectory.appendingPathComponent("cursor-logo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: expectedURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        XCTAssertEqual(
            CursorAPIResources.url(forResource: "cursor-logo", withExtension: "png", in: [temporaryDirectory]),
            expectedURL.standardizedFileURL
        )
    }

    func testMissingResourceReturnsNil() {
        XCTAssertNil(
            CursorAPIResources.url(forResource: "missing", withExtension: "png", in: [FileManager.default.temporaryDirectory])
        )
    }
}
