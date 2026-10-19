import Foundation

/// Align only a previous suffix with the next page's prefix. Never globally unique message text.
enum PageOverlap {
    static func merge(_ previous: [String], _ incoming: [String]) -> [String] {
        guard !previous.isEmpty, !incoming.isEmpty else { return previous + incoming }
        let base = max(0, previous.count - 160)
        let a = Array(previous[base...]), b = Array(incoming.prefix(160))
        let ak = a.map(key), bk = b.map(key)
        let n = a.count, m = b.count
        var scores = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        var moves = scores
        for j in 1...m { scores[0][j] = -2 * j; moves[0][j] = 2 }
        for i in 1...n {
            for j in 1...m {
                let beforeTimestamp = i < n && j < m && isTimestamp(ak[i]) && isTimestamp(bk[j])
                let diagonal = similar(ak[i - 1], bk[j - 1], beforeTimestamp: beforeTimestamp)
                    ? scores[i - 1][j - 1] + 3 : -100_000
                let up = scores[i - 1][j] - 2, left = scores[i][j - 1] - 2
                scores[i][j] = max(diagonal, up, left)
                moves[i][j] = diagonal == scores[i][j] ? 0 : (up == scores[i][j] ? 1 : 2)
            }
        }
        var best: (score: Int, start: Int, end: Int, steps: [(Int?, Int?)])?
        for end in 1...m where scores[n][end] > 0 {
            var i = n, j = end
            var steps: [(Int?, Int?)] = [], matches: [(Int, Int)] = []
            while j > 0 {
                if moves[i][j] == 0 {
                    i -= 1; j -= 1; steps.append((i, j)); matches.append((i, j))
                } else if moves[i][j] == 1 {
                    i -= 1; steps.append((i, nil))
                } else {
                    j -= 1; steps.append((nil, j))
                }
            }
            let anchors = Set(matches.map { ak[$0.0] }.filter { $0.count >= 6 && !isTimestamp($0) })
            let matchedLeft = Set(matches.map(\.0)), matchedRight = Set(matches.map(\.1))
            let oldTimes = (i..<n).filter { !matchedLeft.contains($0) && isCompleteTimestamp(ak[$0]) }
            let newTimes = (0..<end).filter { !matchedRight.contains($0) && isCompleteTimestamp(bk[$0]) }
            guard matches.count >= 3, anchors.reduce(0, { $0 + $1.count }) >= 12,
                  oldTimes.isEmpty || newTimes.isEmpty,
                  Double(matches.count) / Double(max(n - i, end)) >= 0.7,
                  (matches.map(\.1).min() ?? 3) <= 2,
                  (matches.map(\.0).max() ?? 0) >= n - 3 else { continue }
            if best == nil || scores[n][end] > best!.score {
                best = (scores[n][end], i, end, steps.reversed())
            }
        }
        if let best {
            var merged = Array(previous.prefix(base + best.start))
            let matchedLeft = Set(best.steps.compactMap { $0.0 != nil && $0.1 != nil ? $0.0 : nil })
            let matchedRight = Set(best.steps.compactMap { $0.0 != nil && $0.1 != nil ? $0.1 : nil })
            // A badly OCR'd sender can still be identified by the aligned timestamp and message context.
            let duplicateSenders = Set(best.steps.compactMap { left, right -> Int? in
                guard let left, let right, left > 0, right > 0,
                      isTimestamp(ak[left]), isTimestamp(bk[right]),
                      !matchedLeft.contains(left - 1), !matchedRight.contains(right - 1),
                      isSender(ak[left - 1]), isSender(bk[right - 1]) else { return nil }
                return right - 1
            })
            for (left, right) in best.steps {
                if let left {
                    // A clipped line may become complete after scrolling.
                    if let right, bk[right].contains(ak[left]), bk[right].count > ak[left].count {
                        merged.append(b[right])
                    } else { merged.append(a[left]) }
                } else if let right, !duplicateSenders.contains(right) { merged.append(b[right]) }
            }
            return merged + incoming.dropFirst(best.end)
        }
        // Small exact overlaps remain useful when there is not enough context for fuzzy alignment.
        for count in stride(from: min(n, m), through: 1, by: -1) {
            if Array(ak.suffix(count)) == Array(bk.prefix(count)) {
                return previous + incoming.dropFirst(count)
            }
        }
        return previous + incoming
    }

    static func key(_ text: String) -> String {
        let value = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return value.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }

    private static func isTimestamp(_ text: String) -> Bool {
        text.range(of: #"\d{4}年\d{1,2}月\d{1,2}日"#, options: .regularExpression) != nil
    }

    private static func isCompleteTimestamp(_ text: String) -> Bool {
        text.range(of: #"^\d{4}年\d{1,2}月\d{1,2}日\d{4}$"#, options: .regularExpression) != nil
    }

    private static func isSender(_ text: String) -> Bool {
        (1...32).contains(text.count) && text.allSatisfy { $0.isASCII }
            && text.contains(where: \.isLetter)
    }

    private static func similar(_ lhs: String, _ rhs: String, beforeTimestamp: Bool) -> Bool {
        if lhs == rhs { return !lhs.isEmpty }
        guard min(lhs.count, rhs.count) >= 6 else { return false }
        // Do not merge two different, completely recognized message times.
        if isTimestamp(lhs), isTimestamp(rhs), lhs.count == rhs.count { return false }
        let latinNames = beforeTimestamp && lhs.count <= 32 && rhs.count <= 32
            && (lhs + rhs).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard latinNames || (isTimestamp(lhs) && isTimestamp(rhs)) else { return false }
        let a = Array(lhs), b = Array(rhs), limit = min(2, max(a.count, b.count) / 5)
        guard abs(a.count - b.count) <= limit else { return false }
        var row = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (character == b[j - 1] ? 0 : 1))
            }
            row = next
        }
        return row[b.count] <= limit
    }
}
