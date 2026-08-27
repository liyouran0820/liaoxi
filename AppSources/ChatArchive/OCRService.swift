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
                    let luminance = inkLuminance(in: image, normalizedBounds: observation.boundingBox)
                    let tone: TextTone
                    if let luminance {
                        tone = luminance >= 112 ? .muted : .primary
                    } else {
                        tone = .unknown
                    }
                    return RecognizedLine(
                        text: text,
                        bounds: observation.boundingBox,
                        confidence: candidate.confidence,
                        tone: tone
                    )
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

    private func inkLuminance(in image: CGImage, normalizedBounds: CGRect) -> Double? {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let pixelRect = CGRect(
            x: normalizedBounds.minX * imageWidth,
            y: (1 - normalizedBounds.maxY) * imageHeight,
            width: normalizedBounds.width * imageWidth,
            height: normalizedBounds.height * imageHeight
        )
        .insetBy(dx: -2, dy: -2)
        .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        .integral

        guard pixelRect.width >= 2,
              pixelRect.height >= 2,
              let crop = image.cropping(to: pixelRect) else { return nil }

        let width = min(crop.width, 360)
        let height = min(crop.height, 72)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))

        var ink: [Double] = []
        ink.reserveCapacity(width * height / 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = 0.2126 * Double(pixels[index])
                + 0.7152 * Double(pixels[index + 1])
                + 0.0722 * Double(pixels[index + 2])
            if luminance < 225 { ink.append(luminance) }
        }
        guard ink.count >= 4 else { return nil }
        ink.sort()
        return ink[ink.count / 3]
    }
}
