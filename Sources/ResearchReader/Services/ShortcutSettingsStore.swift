import AppKit
import Combine
import Foundation

enum AppShortcutAction: String, CaseIterable, Identifiable {
    case focusReader
    case backToLibrary
    case togglePiChat
    case highlightSelection
    case addNote
    case toggleNotebook
    case undo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focusReader:
            return "Open Paper"
        case .backToLibrary:
            return "Back To Library"
        case .togglePiChat:
            return "Toggle Pi Chat"
        case .highlightSelection:
            return "Highlight Selection"
        case .addNote:
            return "Add Note"
        case .toggleNotebook:
            return "Toggle Notebook"
        case .undo:
            return "Undo"
        }
    }

    var helpText: String {
        switch self {
        case .focusReader:
            return "Expand the selected paper into the focused reader."
        case .backToLibrary:
            return "Return from the focused reader to the library view."
        case .togglePiChat:
            return "Show or hide the floating Pi chat panel."
        case .highlightSelection:
            return "Create a saved highlight from the current PDF selection."
        case .addNote:
            return "Open the note composer for the current PDF."
        case .toggleNotebook:
            return "Show or hide the project notebook panel."
        case .undo:
            return "Undo the last annotation action (highlight or note)."
        }
    }
}

struct AppShortcut: Codable, Equatable {
    var key: String
    var modifiersRawValue: UInt

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    var displayString: String {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        let modifiersText = [
            relevant.contains(.control) ? "⌃" : "",
            relevant.contains(.option) ? "⌥" : "",
            relevant.contains(.shift) ? "⇧" : "",
            relevant.contains(.command) ? "⌘" : "",
        ].joined()

        return modifiersText + prettyKey
    }

    func matches(_ event: NSEvent) -> Bool {
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let eventKey = AppShortcut.normalizedKey(from: event)
        return relevantModifiers == modifiers && eventKey == key
    }

    private var prettyKey: String {
        switch key {
        case " ":
            return "Space"
        case "\r":
            return "↩"
        case "\u{1b}":
            return "⎋"
        case "\t":
            return "⇥"
        default:
            return key.uppercased()
        }
    }

    static func from(event: NSEvent) -> AppShortcut? {
        let key = normalizedKey(from: event)
        guard !key.isEmpty else { return nil }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty else { return nil }

        return AppShortcut(key: key, modifiersRawValue: modifiers.rawValue)
    }

    static func normalizedKey(from event: NSEvent) -> String {
        (event.charactersIgnoringModifiers ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

@MainActor
final class ShortcutSettingsStore: ObservableObject {
    @Published private(set) var shortcuts: [AppShortcutAction: AppShortcut]

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shortcuts = [:]
        load()
    }

    func shortcut(for action: AppShortcutAction) -> AppShortcut? {
        shortcuts[action]
    }

    func setShortcut(_ shortcut: AppShortcut?, for action: AppShortcutAction) {
        shortcuts[action] = shortcut
        persist(shortcut, for: action)
        objectWillChange.send()
    }

    func matchedAction(for event: NSEvent) -> AppShortcutAction? {
        for action in AppShortcutAction.allCases {
            if let shortcut = shortcuts[action], shortcut.matches(event) {
                return action
            }
        }
        return nil
    }

    private func load() {
        var loaded: [AppShortcutAction: AppShortcut] = [:]
        for action in AppShortcutAction.allCases {
            if let data = defaults.data(forKey: storageKey(for: action)),
               let shortcut = try? decoder.decode(AppShortcut.self, from: data) {
                loaded[action] = shortcut
            } else if let shortcut = Self.defaultShortcuts[action] {
                loaded[action] = shortcut
            }
        }
        shortcuts = loaded
    }

    private func persist(_ shortcut: AppShortcut?, for action: AppShortcutAction) {
        let key = storageKey(for: action)
        if let shortcut, let data = try? encoder.encode(shortcut) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func storageKey(for action: AppShortcutAction) -> String {
        "shortcut.\(action.rawValue)"
    }

    private static let defaultShortcuts: [AppShortcutAction: AppShortcut] = [
        .focusReader: AppShortcut(key: "o", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue),
        .backToLibrary: AppShortcut(key: "b", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue),
        .togglePiChat: AppShortcut(key: "i", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue),
        .highlightSelection: AppShortcut(key: "h", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue),
        .addNote: AppShortcut(key: "n", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue),
        .toggleNotebook: AppShortcut(key: "j", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue),
        .undo: AppShortcut(key: "z", modifiersRawValue: NSEvent.ModifierFlags.command.rawValue),
    ]
}

@MainActor
final class ShortcutEventMonitor: ObservableObject {
    private var monitor: Any?

    func start(handler: @escaping (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event) ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
