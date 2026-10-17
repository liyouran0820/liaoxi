import CoreGraphics
import Foundation
import Vision

struct ContentProcessor {
    private let ignored = Set(["微信", "WeChat", "聊天记录", "搜索", "关闭", "完成"])

    func mergePages(_ pages: [[RecognizedLine]]) -> [String] {
        var result: [String] = []
        for page in pages {
            let lines = page.map(\.text).filter(isUseful)
            appendWithOverlap(lines, to: &result)
        }
        return result
    }

    func mergeAccessibilityPages(_ pages: [[String]]) -> [String] {
        var result: [String] = []
        for page in pages {
            appendWithOverlap(page.filter(isUseful), to: &result)
        }
        return result
    }

    func visibleAccessibilityText(_ values: [String], matching ocr: [RecognizedLine]) -> [String] {
        let visible = normalized(ocr.map(\.text).joined(separator: ""))
        guard !visible.isEmpty else { return [] }
        return values.filter { value in
            let candidate = normalized(value)
            guard candidate.count >= 2 else { return false }
            if visible.contains(candidate) { return true }
            if candidate.count >= 8 {
                let prefix = String(candidate.prefix(min(candidate.count, 8)))
                let suffix = String(candidate.suffix(min(candidate.count, 8)))
                return visible.contains(prefix) && visible.contains(suffix)
            }
            return false
        }
    }

    func chooseText(accessibility: [String], ocr: [String]) -> (lines: [String], usedAccessibility: Bool) {
        let axCharacters = accessibility.reduce(0) { $0 + $1.count }
        let ocrCharacters = ocr.reduce(0) { $0 + $1.count }
        if axCharacters >= 40 && axCharacters >= Int(Double(ocrCharacters) * 0.58) {
            return (accessibility, true)
        }
        return (ocr, false)
    }

    func quoteKeys(in pages: [[RecognizedLine]]) -> Set<String> {
        var result = Set<String>()
        for page in pages {
            let lines = page.sorted { lhs, rhs in
                if abs(lhs.bounds.midY - rhs.bounds.midY) < 0.018 {
                    return lhs.bounds.minX < rhs.bounds.minX
                }
                return lhs.bounds.midY > rhs.bounds.midY
            }
            var previousQuoteLine: RecognizedLine?
            for line in lines {
                guard line.tone == .muted else {
                    previousQuoteLine = nil
                    continue
                }

                let startsQuote = hasQuoteAttribution(line.text)
                let continuesQuote: Bool
                if let previousQuoteLine {
                    let verticalGap = previousQuoteLine.bounds.minY - line.bounds.maxY
                    continuesQuote = verticalGap >= -0.01
                        && verticalGap <= 0.04
                        && abs(previousQuoteLine.bounds.minX - line.bounds.minX) <= 0.035
                } else {
                    continuesQuote = false
                }

                if startsQuote || continuesQuote {
                    result.insert(normalized(line.text))
                    previousQuoteLine = line
                } else {
                    previousQuoteLine = nil
                }
            }
        }
        return result
    }

    func extractAttachments(from pages: [PageCapture]) async throws -> [ExtractedAttachment] {
        var attachments: [ExtractedAttachment] = []
        for (pageIndex, page) in pages.enumerated() {
            let request = VNDetectRectanglesRequest()
            request.maximumObservations = 14
            request.minimumSize = 0.11
            request.minimumAspectRatio = 0.28
            request.maximumAspectRatio = 1.0
            request.quadratureTolerance = 18
            let handler = VNImageRequestHandler(cgImage: page.image, orientation: .up)
            try handler.perform([request])
            let rectangles = (request.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            for (candidateIndex, rectangle) in rectangles.enumerated() {
                let normalized = rectangle.boundingBox
                guard normalized.width * normalized.height < 0.46 else { continue }
                let textCoverage = page.lines.reduce(CGFloat.zero) { partial, line in
                    partial + line.bounds.intersection(normalized).area
                } / max(normalized.area, 0.0001)
                guard textCoverage < 0.18 else { continue }
                guard let crop = crop(page.image, normalizedRect: normalized), isVisuallyRich(crop) else { continue }
                let hash = imageHash(crop)
                guard !attachments.contains(where: { hammingDistance($0.hash, hash) <= 5 }) else { continue }
                let fileName = String(format: "image-%03d-%02d.png", pageIndex + 1, candidateIndex + 1)
                attachments.append(ExtractedAttachment(fileName: fileName, image: crop, hash: hash))
            }
        }
        return attachments
    }

    func mediaRegions(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 20
        request.minimumSize = 0.08
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).map(\.boundingBox).filter {
            $0.width > 0.16 && $0.width * $0.height < 0.5 && $0.midY > 0.04 && $0.midY < 0.92
        }
    }

    func likelyFileNames(in lines: [String]) -> [String] {
        let pattern = #"(?i)(?:^|[\s：:（(【\[])([^/\\:*?\"<>|\n]{1,120}\.(?:pdf|docx?|xlsx?|pptx?|zip|rar|7z|txt|md|csv|json|ya?ml|png|jpe?g|gif|webp|heic|mp4|mov|m4v|avi|mkv|webm|mp3|wav))(?=$|[\s：:）)】\]])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: [String] = []
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, range: range) {
                guard match.numberOfRanges > 1,
                      let swiftRange = Range(match.range(at: 1), in: line) else { continue }
                var name = String(line[swiftRange]).trimmingCharacters(in: .whitespaces)
                let commonPrefixes = ["请查看 ", "请打开 ", "请下载 ", "附件 ", "文件 ", "配置 "]
                if let prefix = commonPrefixes.first(where: { name.hasPrefix($0) }) {
                    name.removeFirst(prefix.count)
                }
                if !found.contains(name) { found.append(name) }
            }
        }
        return found
    }

    private func appendWithOverlap(_ incoming: [String], to result: inout [String]) {
        guard !incoming.isEmpty else { return }
        let maxOverlap = min(result.count, incoming.count)
        var overlap = 0
        if maxOverlap > 0 {
            for count in stride(from: maxOverlap, through: 1, by: -1) {
                let suffix = result.suffix(count).map(normalized)
                let prefix = incoming.prefix(count).map(normalized)
                if Array(suffix) == Array(prefix) {
                    overlap = count
                    break
                }
            }
        }
        result.append(contentsOf: incoming.dropFirst(overlap))
    }

    private func isUseful(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !ignored.contains(trimmed)
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    private func hasQuoteAttribution(_ text: String) -> Bool {
        guard !text.contains("年") || !text.contains("月") else { return false }
        guard let separator = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let name = text[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let content = text[text.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...32).contains(name.count) && !content.isEmpty
    }

    private func crop(_ image: CGImage, normalizedRect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(
            x: normalizedRect.minX * width,
            y: (1 - normalizedRect.maxY) * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        ).insetBy(dx: 3, dy: 3).integral
        guard rect.width >= 110, rect.height >= 90 else { return nil }
        return image.cropping(to: rect)
    }

    private func isVisuallyRich(_ image: CGImage) -> Bool {
        guard let samples = luminanceSamples(image, size: 16) else { return false }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(samples.count)
        let dark = samples.filter { $0 < 40 }.count
        let light = samples.filter { $0 > 225 }.count
        return variance.squareRoot() > 22 && dark < samples.count * 9 / 10 && light < samples.count * 9 / 10
    }

    private func imageHash(_ image: CGImage) -> UInt64 {
        guard let values = luminanceSamples(image, size: 8) else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.enumerated().reduce(UInt64.zero) { partial, item in
            item.element >= mean ? partial | (UInt64(1) << UInt64(item.offset)) : partial
        }
    }

    private func luminanceSamples(_ image: CGImage, size: Int) -> [Double]? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return stride(from: 0, to: pixels.count, by: 4).map { index in
            0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
