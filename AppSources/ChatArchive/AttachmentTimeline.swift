import CoreGraphics
import CryptoKit
import Foundation

struct PositionedAttachment {
    let file: URL
    let bounds: CGRect

    var marker: String {
        let hash = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "[[liaoxi-attachment:\(hash)]]"
    }
}

enum AttachmentTimeline {
    static func isMarker(_ text: String) -> Bool { text.hasPrefix("[[liaoxi-attachment:") && text.hasSuffix("]]") }

    static func inserting(_ attachments: [PositionedAttachment], into lines: [RecognizedLine]) -> [RecognizedLine] {
        var result = lines
        for attachment in attachments {
            // Two independent message positions can reference one retained file.
            guard !result.contains(where: { $0.text == attachment.marker && abs($0.bounds.midY - attachment.bounds.midY) < 0.01 }) else { continue }
            let marker = RecognizedLine(text: attachment.marker, bounds: attachment.bounds, confidence: 1)
            let index = result.firstIndex { $0.bounds.midY < attachment.bounds.midY } ?? result.endIndex
            result.insert(marker, at: index)
        }
        return result
    }

    /// Project OCR locations onto AX text only when neighbouring context identifies a unique boundary.
    static func projecting(_ timeline: [String], onto text: [String]) -> [String] {
        let keys = text.map(PageOverlap.key)
        var insertions: [Int: [String]] = [:]
        for (index, marker) in timeline.enumerated() where isMarker(marker) {
            let before = timeline[..<index].filter { !isMarker($0) }.suffix(3).map(PageOverlap.key)
            let after = timeline.dropFirst(index + 1).filter { !isMarker($0) }.prefix(3).map(PageOverlap.key)
            var bestScore = 0, best: [Int] = []
            for boundary in 0...text.count {
                var score = 0
                for (left, right) in zip(before.reversed(), keys.prefix(boundary).reversed()) {
                    guard left == right else { break }; score += 1
                }
                for (left, right) in zip(after, keys.dropFirst(boundary)) {
                    guard left == right else { break }; score += 1
                }
                if score > bestScore { bestScore = score; best = [boundary] }
                else if score == bestScore { best.append(boundary) }
            }
            if bestScore >= 2, best.count == 1 { insertions[best[0], default: []].append(marker) }
        }
        var result: [String] = []
        for index in 0...text.count {
            result += insertions[index] ?? []
            if index < text.count { result.append(text[index]) }
        }
        return result
    }
}
