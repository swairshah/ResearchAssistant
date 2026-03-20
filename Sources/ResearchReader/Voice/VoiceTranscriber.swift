import Foundation

final class VoiceTranscriber {
    enum TranscriptionError: Error, LocalizedError {
        case binaryNotFound
        case modelNotFound(String)
        case transcriptionFailed(String)
        case noOutput

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "qwen_asr binary not found"
            case .modelNotFound(let path):
                return "STT model not found at: \(path)"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .noOutput:
                return "No transcription output"
            }
        }
    }

    private let modelPath: String

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func transcribe(audioURL: URL) async throws -> String {
        let binaryURL = try findBinary()

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TranscriptionError.modelNotFound(modelPath)
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "-d", modelPath,
            "-i", audioURL.path,
            "--silent",
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
                process.terminationHandler = { _ in
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    let output = String(data: outputData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: TranscriptionError.transcriptionFailed(errorOutput))
                        return
                    }

                    if output.isEmpty {
                        continuation.resume(throwing: TranscriptionError.noOutput)
                        return
                    }

                    continuation.resume(returning: output)
                }
            } catch {
                continuation.resume(throwing: TranscriptionError.transcriptionFailed(error.localizedDescription))
            }
        }
    }

    private func findBinary() throws -> URL {
        if let bundleURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("qwen_asr"),
           FileManager.default.isExecutableFile(atPath: bundleURL.path) {
            return bundleURL
        }

        if let bundleURL = Bundle.main.url(forResource: "qwen_asr", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundleURL.path) {
            return bundleURL
        }

        let candidates = [
            "/opt/homebrew/bin/qwen_asr",
            "/usr/local/bin/qwen_asr",
            NSHomeDirectory() + "/.local/bin/qwen_asr",
            NSHomeDirectory() + "/work/misc/qwen-asr/qwen_asr",
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        throw TranscriptionError.binaryNotFound
    }

    static func findModelPath() -> String? {
        let hearsayModels = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Hearsay/Models")

        if let models = try? FileManager.default.contentsOfDirectory(at: hearsayModels, includingPropertiesForKeys: nil) {
            for model in models.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: model.path, isDirectory: &isDir), isDir.boolValue {
                    return model.path
                }
            }
        }

        let localTalkerModels = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".LocalTalker/Models/qwen-asr", isDirectory: true)
        if FileManager.default.fileExists(atPath: localTalkerModels.path) {
            return localTalkerModels.path
        }

        let devPath = NSHomeDirectory() + "/work/misc/qwen-asr/qwen3-asr-0.6b"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return nil
    }
}
