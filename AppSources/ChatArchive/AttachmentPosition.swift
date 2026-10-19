import CoreGraphics
import Foundation

/// Metadata only. These values never enter OCR, text-source selection or page deduplication.
struct AttachmentPosition {
    let file: URL
    let before: [String]
    let after: [String]
    let page: Int
    let verticalPosition: CGFloat

    init(file: URL, bounds: CGRect, lines: [RecognizedLine], page: Int) {
        self.file = file
        before = Array(lines.filter { $0.bounds.midY > bounds.maxY }.map(\.text).suffix(6))
        after = Array(lines.filter { $0.bounds.midY < bounds.minY }.map(\.text).prefix(6))
        self.page = page
        verticalPosition = bounds.midY
    }

    init(file: URL, before: [String], after: [String], page: Int = 0, verticalPosition: CGFloat = 0) {
        self.file = file; self.before = before; self.after = after
        self.page = page; self.verticalPosition = verticalPosition
    }
}

enum AttachmentPositionResolver {
    static func resolve(_ positions: [AttachmentPosition], in lines: [String]) -> [Int: [URL]] {
        let keys = lines.map(PageOverlap.key)
        var result: [Int: [URL]] = [:]
        let ordered = positions.enumerated().sorted {
            if $0.element.page != $1.element.page { return $0.element.page < $1.element.page }
            if $0.element.verticalPosition != $1.element.verticalPosition { return $0.element.verticalPosition > $1.element.verticalPosition }
            return $0.offset < $1.offset
        }.map(\.element)
        for position in ordered {
            let before = position.before.suffix(6).map(PageOverlap.key)
            let after = position.after.prefix(6).map(PageOverlap.key)
            var bestScore = 0, best: [Int] = []
            for boundary in 0...lines.count {
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
            guard bestScore >= 2, best.count == 1 else { continue }
            let file = position.file.standardizedFileURL
            if !(result[best[0]] ?? []).contains(file) { result[best[0], default: []].append(file) }
        }
        return result
    }
}
