import Foundation

struct AppPaths {
    let rootDirectory: URL
    let pdfsDirectory: URL
    let libraryFile: URL
    let chatHistoryFile: URL
    let piSessionDirectory: URL
    let piConfigDirectory: URL
    let piBridgeDirectory: URL
    let piBridgeCommandsDirectory: URL
    let piBridgeResultsDirectory: URL
    let piBridgeContextFile: URL
    let piExtensionDirectory: URL
    let piExtensionFile: URL

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
        let chatHistory = root.appendingPathComponent("agent-chat-history.json", isDirectory: false)
        let piSessions = root.appendingPathComponent("sessions/research-reader-agent", isDirectory: true)
        let piConfig = root.appendingPathComponent("pi-agent", isDirectory: true)
        let piBridge = root.appendingPathComponent("pi-bridge", isDirectory: true)
        let piCommands = piBridge.appendingPathComponent("commands", isDirectory: true)
        let piResults = piBridge.appendingPathComponent("results", isDirectory: true)
        let piContext = piBridge.appendingPathComponent("context.json", isDirectory: false)
        let piExtensionDirectory = root.appendingPathComponent("pi-extension", isDirectory: true)
        let piExtensionFile = piExtensionDirectory.appendingPathComponent("index.js", isDirectory: false)

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: pdfs, withIntermediateDirectories: true)
        try fm.createDirectory(at: piSessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: piConfig, withIntermediateDirectories: true)
        try fm.createDirectory(at: piBridge, withIntermediateDirectories: true)
        try fm.createDirectory(at: piCommands, withIntermediateDirectories: true)
        try fm.createDirectory(at: piResults, withIntermediateDirectories: true)
        try fm.createDirectory(at: piExtensionDirectory, withIntermediateDirectories: true)

        return AppPaths(
            rootDirectory: root,
            pdfsDirectory: pdfs,
            libraryFile: library,
            chatHistoryFile: chatHistory,
            piSessionDirectory: piSessions,
            piConfigDirectory: piConfig,
            piBridgeDirectory: piBridge,
            piBridgeCommandsDirectory: piCommands,
            piBridgeResultsDirectory: piResults,
            piBridgeContextFile: piContext,
            piExtensionDirectory: piExtensionDirectory,
            piExtensionFile: piExtensionFile
        )
    }
}
