import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var shortcuts: ShortcutSettingsStore

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                Text("These shortcuts are active while ResearchReader is focused.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(AppShortcutAction.allCases) { action in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.title)
                                .font(.body.weight(.medium))
                            Text(action.helpText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        ShortcutRecorder(
                            shortcut: shortcuts.shortcut(for: action),
                            onChange: { shortcuts.setShortcut($0, for: action) }
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620, height: 360)
    }
}

private struct ShortcutRecorder: View {
    let shortcut: AppShortcut?
    let onChange: (AppShortcut?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(isRecording ? "Type Shortcut…" : (shortcut?.displayString ?? "Set Shortcut")) {
                toggleRecording()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            if shortcut != nil {
                Button("Clear") {
                    stopRecording()
                    onChange(nil)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        stopRecording()
        isRecording = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }

            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            if let shortcut = AppShortcut.from(event: event) {
                onChange(shortcut)
                stopRecording()
                return nil
            }

            NSSound.beep()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
