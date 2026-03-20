import Foundation

enum VoiceInputConstants {
    static let sampleRate: Double = 16_000
    static let vadChunkSize: Int = 512
    static let vadSpeechThreshold: Float = 0.5
    static let vadSpeechMinChunks: Int = 4
    static let vadSilenceDurationMs: Int = 600

    static var vadSilenceChunks: Int {
        let chunkDurationMs = Double(vadChunkSize) / sampleRate * 1000
        return Int(Double(vadSilenceDurationMs) / chunkDurationMs)
    }

    static let tempAudioURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("research-reader-voice.wav")

    static let sileroModelDownloadURL = URL(string: "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx")!

    static var appSupportRoot: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ResearchReader", isDirectory: true)
    }

    static var modelsDir: URL {
        appSupportRoot.appendingPathComponent("Models", isDirectory: true)
    }

    static var defaultSileroModelPath: URL {
        modelsDir.appendingPathComponent("silero_vad.onnx", isDirectory: false)
    }

    static func resolveSileroModelPath() -> URL {
        let fm = FileManager.default

        if fm.fileExists(atPath: defaultSileroModelPath.path) {
            return defaultSileroModelPath
        }

        let localTalkerResource = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("work/projects/LocalTalker/Resources/models/silero_vad.onnx", isDirectory: false)
        if fm.fileExists(atPath: localTalkerResource.path) {
            return localTalkerResource
        }

        return defaultSileroModelPath
    }
}
