import AppKit
import Foundation

enum CursorAPIResources {
    private static let resourceBundleName = "CursorAPI_CursorAPI.bundle"

    static func image(named name: String, withExtension fileExtension: String = "png") -> NSImage? {
        url(forResource: name, withExtension: fileExtension).flatMap(NSImage.init(contentsOf:))
    }

    static func url(forResource name: String, withExtension fileExtension: String) -> URL? {
        url(forResource: name, withExtension: fileExtension, in: defaultSearchRoots())
    }

    static func url(forResource name: String, withExtension fileExtension: String, in searchRoots: [URL]) -> URL? {
        let filename = "\(name).\(fileExtension)"
        let fileManager = FileManager.default

        for root in expandedSearchRoots(searchRoots) {
            let candidate = root.appendingPathComponent(filename, isDirectory: false)
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }

        return nil
    }

    private static func expandedSearchRoots(_ roots: [URL]) -> [URL] {
        uniqueURLs(
            roots.flatMap { root in
                [
                    root,
                    root.appendingPathComponent(resourceBundleName, isDirectory: true),
                    root.appendingPathComponent("Contents/Resources", isDirectory: true),
                    root.appendingPathComponent("Contents/Resources/\(resourceBundleName)", isDirectory: true)
                ]
            }
        )
    }

    private static func defaultSearchRoots() -> [URL] {
        let mainBundle = Bundle.main
        var roots: [URL] = []

        if let resourceURL = mainBundle.resourceURL {
            roots.append(resourceURL)
        }
        roots.append(mainBundle.bundleURL)
        if let executableDirectory = mainBundle.executableURL?.deletingLastPathComponent() {
            roots.append(executableDirectory)
        }

        return uniqueURLs(roots)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let standardized = url.standardizedFileURL
            let key = standardized.path
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(standardized)
        }

        return result
    }
}
