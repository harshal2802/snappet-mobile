import Foundation
import OnnxRuntimeBindings

/// The ONNX Runtime edge — the *only* file that imports `onnxruntime`. Wraps an `ORTSession` over the
/// downloaded `model.q.onnx` and exposes it as a `KilterLogitsProviding`, so the pure decode loop
/// (`KilterClimbGenerator`) never touches the binary dependency. The model takes a single int64 `tokens`
/// input `[1, block]` (the sequence left-packed, the rest `pad`) and returns `logits` `[1, block, vocab]`;
/// we read the slice at the last real token's position.
final class KilterORTSession: KilterLogitsProviding {
    private let env: ORTEnv
    private let session: ORTSession
    private let block: Int
    private let pad: Int

    init(modelURL: URL, block: Int, pad: Int) throws {
        self.env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: nil)
        self.block = block
        self.pad = pad
    }

    func logits(forTokens tokens: [Int]) throws -> [Float] {
        // Left-pack the sequence into a block-length int64 buffer, the rest filled with `pad`.
        var buffer = [Int64](repeating: Int64(pad), count: block)
        for (i, t) in tokens.prefix(block).enumerated() { buffer[i] = Int64(t) }
        let data = buffer.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }

        let input = try ORTValue(tensorData: data,
                                 elementType: ORTTensorElementDataType.int64,
                                 shape: [1, NSNumber(value: block)])
        let outputs = try session.run(withInputs: ["tokens": input],
                                      outputNames: ["logits"],
                                      runOptions: nil)
        guard let logitsValue = outputs["logits"] else { return [] }

        let shape = try logitsValue.tensorTypeAndShapeInfo().shape   // [1, block, vocab]
        let vocab = shape.last?.intValue ?? 0
        guard vocab > 0 else { return [] }
        let raw = try logitsValue.tensorData() as Data
        let floats: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        // Logits at the position of the last real token.
        let position = max(0, min(tokens.count, block) - 1)
        let start = position * vocab
        guard start + vocab <= floats.count else { return [] }
        return Array(floats[start..<start + vocab])
    }
}

/// Owns the (non-Sendable) ONNX session and runs generation off the main actor. An `actor` so the session
/// is created once and reused across "Generate another" taps, and never crosses an isolation boundary —
/// only the `Sendable` `KilterGeneratedClimb` result does. The UI awaits `generate`.
actor KilterGeneratorRuntime {
    private let model: KilterGeneratorModel
    private let modelURL: URL
    private var ort: KilterORTSession?

    init(model: KilterGeneratorModel, modelURL: URL) {
        self.model = model
        self.modelURL = modelURL
    }

    /// Generate a climb for the request (creating the ONNX session lazily on first call). Runs the
    /// sampler with the system RNG.
    func generate(_ request: KilterGenerateRequest) throws -> KilterGeneratedClimb {
        let session: KilterORTSession
        if let existing = ort {
            session = existing
        } else {
            session = try KilterORTSession(modelURL: modelURL, block: model.meta.block, pad: model.meta.pad)
            ort = session
        }
        let generator = KilterClimbGenerator(model: model, session: session)
        var rng = SystemRandomNumberGenerator()
        return try generator.generate(request) { Double.random(in: 0..<1, using: &rng) }
    }
}
