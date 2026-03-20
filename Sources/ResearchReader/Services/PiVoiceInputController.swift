import Foundation

@MainActor
final class PiVoiceInputController: ObservableObject {
    enum State: Equatable {
        case off
        case listening
        case transcribing
        case error(String)

        var label: String {
            switch self {
            case .off: return "Mic Off"
            case .listening: return "Listening"
            case .transcribing: return "Transcribing"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    @Published private(set) var isActive = false
    @Published private(set) var state: State = .off
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastTranscript: String?

    var onTranscript: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let audioCapture = VoiceAudioCaptureSession()
    private let audioBuffer = VoiceAudioBuffer()

    private var vad: VoiceSileroVAD?
    private var transcriber: VoiceTranscriber?
    private var activeTranscriptionTask: Task<Void, Never>?

    init() {
        audioCapture.onAudioFrame = { [weak self] samples in
            Task { @MainActor [weak self] in
                self?.processAudioFrame(samples)
            }
        }

        audioCapture.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            Task { await start() }
        }
    }

    func stop() {
        activeTranscriptionTask?.cancel()
        activeTranscriptionTask = nil

        audioCapture.stop()
        audioBuffer.reset()
        vad?.reset()

        isActive = false
        audioLevel = 0
        state = .off
    }

    private func start() async {
        guard !isActive else { return }

        guard await VoiceAudioCaptureSession.checkPermission() else {
            state = .error("Microphone permission denied")
            onError?("Microphone permission denied")
            return
        }

        do {
            let vadPath = try await ensureVADModelPath()
            vad = try VoiceSileroVAD(modelPath: vadPath)

            guard let sttModelPath = VoiceTranscriber.findModelPath() else {
                throw NSError(domain: "PiVoiceInput", code: 1, userInfo: [NSLocalizedDescriptionKey: "No STT model found. Install qwen-asr model first."])
            }
            transcriber = VoiceTranscriber(modelPath: sttModelPath)

            try audioCapture.start()
            audioBuffer.reset()
            isActive = true
            state = .listening
        } catch {
            isActive = false
            state = .error(error.localizedDescription)
            onError?(error.localizedDescription)
        }
    }

    private func ensureVADModelPath() async throws -> String {
        let existing = VoiceInputConstants.resolveSileroModelPath()
        if FileManager.default.fileExists(atPath: existing.path) {
            return existing.path
        }

        let destination = VoiceInputConstants.defaultSileroModelPath
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let (tempURL, response) = try await URLSession.shared.download(from: VoiceInputConstants.sileroModelDownloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "PiVoiceInput", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to download VAD model (HTTP \(http.statusCode))."])
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination.path
    }

    private func processAudioFrame(_ samples: [Float]) {
        guard isActive,
              state != .transcribing,
              let vad else {
            return
        }

        audioBuffer.append(samples)

        do {
            _ = try vad.processBuffer(samples)
        } catch {
            state = .error("VAD failed: \(error.localizedDescription)")
            onError?("VAD failed: \(error.localizedDescription)")
            return
        }

        if vad.currentEvent == .turnSilence,
           audioBuffer.duration > 0.25,
           activeTranscriptionTask == nil,
           let transcriber {
            let capturedSamples = audioBuffer.getAll()
            audioBuffer.reset()
            vad.reset()

            guard !capturedSamples.isEmpty else {
                state = .listening
                return
            }

            state = .transcribing
            activeTranscriptionTask = Task { [weak self] in
                await self?.transcribe(capturedSamples: capturedSamples, with: transcriber)
            }
        }
    }

    private func transcribe(capturedSamples: [Float], with transcriber: VoiceTranscriber) async {
        defer {
            activeTranscriptionTask = nil
            if isActive {
                state = .listening
            }
        }

        let audioURL = VoiceInputConstants.tempAudioURL
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            let temp = VoiceAudioBuffer()
            temp.append(capturedSamples)
            try temp.saveToWAV(url: audioURL)

            let text = try await transcriber.transcribe(audioURL: audioURL)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, isActive else { return }

            lastTranscript = trimmed
            onTranscript?(trimmed)
        } catch {
            onError?("Transcription failed: \(error.localizedDescription)")
        }
    }
}
