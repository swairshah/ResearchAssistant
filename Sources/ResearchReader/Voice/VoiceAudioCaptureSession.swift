import AVFoundation
import Accelerate

final class VoiceAudioCaptureSession {
    enum CaptureError: Error, LocalizedError {
        case engineSetupFailed(String)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .engineSetupFailed(let msg): return "Audio engine setup failed: \(msg)"
            case .permissionDenied: return "Microphone permission denied"
            }
        }
    }

    var onAudioFrame: (([Float]) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private(set) var engine: AVAudioEngine?
    private var isRunning = false

    deinit {
        stop()
    }

    func start() throws {
        guard !isRunning else { return }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.engineSetupFailed("Invalid input format: \(inputFormat)")
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: VoiceInputConstants.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let converter = AVAudioConverter(from: monoInputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLen = Int(buffer.frameLength)
            guard frameLen > 0 else { return }
            guard let ch0 = buffer.floatChannelData?[0] else { return }

            guard let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoInputFormat,
                frameCapacity: AVAudioFrameCount(frameLen)
            ) else { return }
            monoBuffer.frameLength = AVAudioFrameCount(frameLen)
            memcpy(monoBuffer.floatChannelData![0], ch0, frameLen * MemoryLayout<Float>.size)

            if let converter {
                let ratio = targetFormat.sampleRate / monoInputFormat.sampleRate
                let outFrames = AVAudioFrameCount(Double(monoBuffer.frameLength) * ratio)
                guard outFrames > 0,
                      let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
                    return
                }

                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return monoBuffer
                }

                if status == .haveData {
                    self.deliverBuffer(converted)
                }
            } else {
                self.deliverBuffer(monoBuffer)
            }
        }

        try audioEngine.start()
        engine = audioEngine
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }

    var running: Bool { isRunning }

    private func deliverBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

        var rms: Float = 0
        vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))

        let minDb: Float = -45
        let maxDb: Float = -5
        let db = 20 * log10(max(rms, 0.000001))
        let normalized = (db - minDb) / (maxDb - minDb)
        let level = max(0, min(1, normalized))

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(level)
        }

        onAudioFrame?(samples)
    }

    static func checkPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
