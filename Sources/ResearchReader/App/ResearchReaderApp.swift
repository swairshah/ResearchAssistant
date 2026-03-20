import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ResearchReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @StateObject private var shortcuts = ShortcutSettingsStore()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(store)
                .environmentObject(shortcuts)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(shortcuts)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureAppIcon()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureAppIcon() {
        guard let icon = loadBaseAppIcon() else { return }
        NSApp.applicationIconImage = paddedDockIcon(from: icon, insetFraction: 0.10)
    }

    private func loadBaseAppIcon() -> NSImage? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "icon", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("icon.png", isDirectory: false),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("icon.png", isDirectory: false),
        ]

        for url in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }

    private func paddedDockIcon(from image: NSImage, insetFraction: CGFloat) -> NSImage {
        let side = max(image.size.width, image.size.height)
        let canvasSize = NSSize(width: side, height: side)
        let canvas = NSImage(size: canvasSize)

        canvas.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

        let inset = side * insetFraction
        let drawRect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        image.draw(in: drawRect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1)

        canvas.unlockFocus()
        return canvas
    }
}
