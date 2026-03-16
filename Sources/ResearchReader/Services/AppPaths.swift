import Foundation

struct AppPaths {
    let rootDirectory: URL
    let pdfsDirectory: URL
    let libraryFile: URL

    static func make() throws -> AppPaths {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport.appendingPathComponent("ResearchReader", isDirectory: true)
        let pdfs = root.appendingPathComponent("Papers", isDirectory: true)
        let library = root.appendingPathComponent("library.json", isDirectory: false)

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: pdfs, withIntermediateDirectories: true)

        return AppPaths(rootDirectory: root, pdfsDirectory: pdfs, libraryFile: library)
    }
}
