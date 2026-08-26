import CoreGraphics
import Foundation
@preconcurrency import Vision

struct OCRService {
    func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { observation -> RecognizedLine? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return RecognizedLine(text: text, bounds: observation.boundingBox, confidence: candidate.confidence)
                }
                .sorted { lhs, rhs in
                    let rowDifference = abs(lhs.bounds.midY - rhs.bounds.midY)
                    if rowDifference < 0.018 { return lhs.bounds.minX < rhs.bounds.minX }
                    return lhs.bounds.midY > rhs.bounds.midY
                }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.minimumTextHeight = 0.009

            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
