import Foundation
import COnnxRuntime

final class VoiceOnnxSession {
    enum OnnxError: Error, LocalizedError {
        case runtimeError(String)
        case modelNotFound(String)
        case invalidInput(String)
        case apiInitFailed

        var errorDescription: String? {
            switch self {
            case .runtimeError(let msg): return "ONNX Runtime error: \(msg)"
            case .modelNotFound(let path): return "ONNX model not found: \(path)"
            case .invalidInput(let msg): return "Invalid input: \(msg)"
            case .apiInitFailed: return "Failed to initialize ONNX Runtime API"
            }
        }
    }

    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?
    private var session: OpaquePointer?

    init(modelPath: String, label: String = "research-reader-vad") throws {
        guard let apiBase = OrtGetApiBase(),
              let api = apiBase.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw OnnxError.apiInitFailed
        }
        self.api = api

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw OnnxError.modelNotFound(modelPath)
        }

        var env: OpaquePointer?
        try check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, label, &env))
        self.env = env

        var options: OpaquePointer?
        try check(api.pointee.CreateSessionOptions(&options))
        defer { api.pointee.ReleaseSessionOptions(options) }

        try check(api.pointee.SetIntraOpNumThreads(options, 1))
        try check(api.pointee.SetInterOpNumThreads(options, 1))
        try check(api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))

        var session: OpaquePointer?
        try check(api.pointee.CreateSession(env, modelPath, options, &session))
        self.session = session
    }

    deinit {
        if let session { api.pointee.ReleaseSession(session) }
        if let env { api.pointee.ReleaseEnv(env) }
    }

    func createFloatTensor(_ data: [Float], shape: [Int64]) throws -> OpaquePointer {
        let totalElements = shape.isEmpty ? 1 : shape.reduce(1, *)
        guard data.count == Int(totalElements) else {
            throw OnnxError.invalidInput("Data count \(data.count) does not match shape \(shape)")
        }

        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try check(api.pointee.GetAllocatorWithDefaultOptions(&allocator))

        var tensor: OpaquePointer?
        if shape.isEmpty {
            try check(api.pointee.CreateTensorAsOrtValue(allocator, nil, 0, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor))
        } else {
            var mutableShape = shape
            try mutableShape.withUnsafeMutableBufferPointer { shapePtr in
                try check(api.pointee.CreateTensorAsOrtValue(
                    allocator,
                    shapePtr.baseAddress,
                    shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                    &tensor
                ))
            }
        }

        var rawPtr: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(tensor, &rawPtr))
        data.withUnsafeBufferPointer { src in
            rawPtr?.copyMemory(from: src.baseAddress!, byteCount: data.count * MemoryLayout<Float>.size)
        }

        return tensor!
    }

    func createInt64Tensor(_ data: [Int64], shape: [Int64]) throws -> OpaquePointer {
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try check(api.pointee.GetAllocatorWithDefaultOptions(&allocator))

        var tensor: OpaquePointer?
        if shape.isEmpty {
            try check(api.pointee.CreateTensorAsOrtValue(allocator, nil, 0, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &tensor))
        } else {
            var mutableShape = shape
            try mutableShape.withUnsafeMutableBufferPointer { shapePtr in
                try check(api.pointee.CreateTensorAsOrtValue(
                    allocator,
                    shapePtr.baseAddress,
                    shape.count,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
                    &tensor
                ))
            }
        }

        var rawPtr: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(tensor, &rawPtr))
        data.withUnsafeBufferPointer { src in
            rawPtr?.copyMemory(from: src.baseAddress!, byteCount: data.count * MemoryLayout<Int64>.size)
        }

        return tensor!
    }

    func run(inputs: [(name: String, tensor: OpaquePointer)], outputNames: [String]) throws -> [OpaquePointer] {
        let inputNames = inputs.map(\.name)
        let inputTensors = inputs.map(\.tensor)

        let cInputNames = inputNames.map { strdup($0)! }
        let cOutputNames = outputNames.map { strdup($0)! }
        defer {
            cInputNames.forEach { free($0) }
            cOutputNames.forEach { free($0) }
        }

        var outputTensors = [OpaquePointer?](repeating: nil, count: outputNames.count)

        try cInputNames.withUnsafeBufferPointer { inputNamesPtr in
            try cOutputNames.withUnsafeBufferPointer { outputNamesPtr in
                try inputTensors.withUnsafeBufferPointer { inputTensorsPtr in
                    let inputNamesRaw = UnsafePointer<UnsafePointer<CChar>?>(OpaquePointer(inputNamesPtr.baseAddress!))
                    let outputNamesRaw = UnsafePointer<UnsafePointer<CChar>?>(OpaquePointer(outputNamesPtr.baseAddress!))
                    let inputTensorsRaw = UnsafePointer<OpaquePointer?>(OpaquePointer(inputTensorsPtr.baseAddress!))

                    try check(api.pointee.Run(
                        session,
                        nil,
                        inputNamesRaw,
                        inputTensorsRaw,
                        inputs.count,
                        outputNamesRaw,
                        outputNames.count,
                        &outputTensors
                    ))
                }
            }
        }

        return outputTensors.compactMap { $0 }
    }

    func getFloatOutput(_ tensor: OpaquePointer) throws -> [Float] {
        var data: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(tensor, &data))

        var typeInfo: OpaquePointer?
        try check(api.pointee.GetTypeInfo(tensor, &typeInfo))
        defer { if let typeInfo { api.pointee.ReleaseTypeInfo(typeInfo) } }

        var tensorInfo: OpaquePointer?
        try check(api.pointee.CastTypeInfoToTensorInfo(typeInfo, &tensorInfo))

        var elementCount: Int = 0
        try check(api.pointee.GetTensorShapeElementCount(tensorInfo, &elementCount))

        let floatPtr = data!.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: floatPtr, count: elementCount))
    }

    func releaseTensor(_ tensor: OpaquePointer) {
        api.pointee.ReleaseValue(tensor)
    }

    private func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let msg = api.pointee.GetErrorMessage(status)
        let message = msg.map { String(cString: $0) } ?? "unknown error"
        api.pointee.ReleaseStatus(status)
        throw OnnxError.runtimeError(message)
    }
}
