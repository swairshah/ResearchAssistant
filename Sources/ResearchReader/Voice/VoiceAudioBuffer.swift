import Foundation

final class VoiceAudioBuffer {
    private var samples: [Float] = []
    private let lock = NSLock()
    private let maxSamples = 960_000

    init() {
        samples.reserveCapacity(128_000)
    }

    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        samples.append(contentsOf: newSamples)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    func getAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    var duration: Double {
        Double(count) / VoiceInputConstants.sampleRate
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }

    func saveToWAV(url: URL) throws {
        let current: [Float]
        lock.lock()
        current = samples
        lock.unlock()

        guard !current.isEmpty else {
            throw NSError(domain: "VoiceAudioBuffer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio buffer is empty"])
        }

        let int16Samples: [Int16] = current.map { sample in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        let sampleRate: UInt32 = UInt32(VoiceInputConstants.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        let blockAlign = channels * (bitsPerSample / 8)
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append(contentsOf: "data".utf8)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        var fileData = header
        int16Samples.withUnsafeBufferPointer { ptr in
            fileData.append(contentsOf: UnsafeRawBufferPointer(ptr))
        }

        try fileData.write(to: url)
    }
}
