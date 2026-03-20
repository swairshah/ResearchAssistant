import Foundation

final class VoiceSileroVAD {
    private let session: VoiceOnnxSession
    private var state: [Float]
    private var context: [Float]

    private let contextSize = 64
    private let stateShape: [Int64] = [2, 1, 128]
    private let stateSize = 2 * 1 * 128

    private(set) var isTriggered = false
    private var speechChunkCount = 0
    private var silenceChunkCount = 0

    enum VADEvent {
        case speechContinue
        case silenceDetected
        case turnSilence
        case idle
    }

    init(modelPath: String) throws {
        session = try VoiceOnnxSession(modelPath: modelPath, label: "research-reader-silero-vad")
        state = [Float](repeating: 0, count: stateSize)
        context = [Float](repeating: 0, count: contextSize)
    }

    func process(chunk: [Float]) throws -> Float {
        guard chunk.count == VoiceInputConstants.vadChunkSize else {
            throw VoiceOnnxSession.OnnxError.invalidInput(
                "Expected \(VoiceInputConstants.vadChunkSize) samples, got \(chunk.count)"
            )
        }

        let inputWithContext = context + chunk
        context = Array(chunk.suffix(contextSize))

        let inputTensor = try session.createFloatTensor(inputWithContext, shape: [1, Int64(inputWithContext.count)])
        let srTensor = try session.createInt64Tensor([Int64(VoiceInputConstants.sampleRate)], shape: [])
        let stateTensor = try session.createFloatTensor(state, shape: stateShape)

        defer {
            session.releaseTensor(inputTensor)
            session.releaseTensor(srTensor)
            session.releaseTensor(stateTensor)
        }

        let outputs = try session.run(
            inputs: [
                ("input", inputTensor),
                ("sr", srTensor),
                ("state", stateTensor),
            ],
            outputNames: ["output", "stateN"]
        )

        defer { outputs.forEach { session.releaseTensor($0) } }

        guard outputs.count == 2 else {
            throw VoiceOnnxSession.OnnxError.runtimeError("Expected 2 outputs, got \(outputs.count)")
        }

        let probability = try session.getFloatOutput(outputs[0])
        let newState = try session.getFloatOutput(outputs[1])
        state = newState

        let speechProb = probability.first ?? 0
        updateIteratorState(speechProbability: speechProb)
        return speechProb
    }

    func processBuffer(_ samples: [Float]) throws -> Float {
        var lastProb: Float = 0
        var offset = 0
        while offset + VoiceInputConstants.vadChunkSize <= samples.count {
            let chunk = Array(samples[offset..<offset + VoiceInputConstants.vadChunkSize])
            lastProb = try process(chunk: chunk)
            offset += VoiceInputConstants.vadChunkSize
        }
        return lastProb
    }

    var currentEvent: VADEvent {
        if isTriggered {
            if silenceChunkCount >= VoiceInputConstants.vadSilenceChunks {
                return .turnSilence
            } else if silenceChunkCount > 0 {
                return .silenceDetected
            } else {
                return .speechContinue
            }
        }
        return .idle
    }

    func reset() {
        state = [Float](repeating: 0, count: stateSize)
        context = [Float](repeating: 0, count: contextSize)
        isTriggered = false
        speechChunkCount = 0
        silenceChunkCount = 0
    }

    private func updateIteratorState(speechProbability: Float) {
        if speechProbability >= VoiceInputConstants.vadSpeechThreshold {
            speechChunkCount += 1
            silenceChunkCount = 0
            if !isTriggered && speechChunkCount >= VoiceInputConstants.vadSpeechMinChunks {
                isTriggered = true
            }
        } else {
            if isTriggered {
                silenceChunkCount += 1
            } else {
                speechChunkCount = 0
            }
        }
    }
}
