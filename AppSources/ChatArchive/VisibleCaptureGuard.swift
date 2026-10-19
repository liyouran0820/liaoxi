import CoreGraphics
import Foundation

struct VisibleWindowInfo {
    let id: CGWindowID
    let owner: pid_t
    let frame: CGRect
    var alpha: Double = 1
}

enum VisibleCaptureError: LocalizedError {
    case unavailable, moved, covered, notForeground, blank, wrongContent

    var errorDescription: String? {
        switch self {
        case .unavailable: return "记录窗口没有完整显示在同一屏幕内。请将合并记录移到当前屏幕并保持可见。"
        case .moved: return "记录窗口位置或大小已改变，请停止移动窗口并重新开始提取。"
        case .covered: return "记录区域被其他窗口或菜单遮挡，已停止截图，避免读取遮挡内容。请将合并记录完整置前后重试。"
        case .notForeground: return "微信记录未处于前台，已停止截图。请返回合并记录后重试。"
        case .blank: return "屏幕上的记录区域仍为空白，未读取到聊天内容。请先确认微信记录已经显示。"
        case .wrongContent: return "截图未显示这条合并记录的标题，已停止，避免误读其他画面。请将该记录完整置前后重试。"
        }
    }
}

enum VisibleCaptureGuard {
    static func headerMatches(expected: String, recognized: [String]) -> Bool {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let needle = key(expected)
        guard !needle.isEmpty else { return false }
        let candidates = recognized.map(key) + [key(recognized.joined())]
        if candidates.contains(where: { $0.contains(needle) }) { return true }
        guard needle.count >= 8 else { return false }
        let a = Array(needle), limit = min(2, needle.count / 8)
        for candidate in candidates where abs(candidate.count - needle.count) <= limit {
            let b = Array(candidate)
            var row = Array(0...b.count)
            for (i, character) in a.enumerated() {
                var next = [i + 1] + Array(repeating: 0, count: b.count)
                if !b.isEmpty { for j in 1...b.count {
                    next[j] = min(row[j] + 1, next[j-1] + 1, row[j-1] + (character == b[j-1] ? 0 : 1))
                } }
                row = next
            }
            if row[b.count] <= limit { return true }
        }
        return false
    }

    // CGWindowListCopyWindowInfo returns front-to-back order. Do not log titles or other app contents.
    static func windowList() throws -> [VisibleWindowInfo] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw VisibleCaptureError.unavailable
        }
        return rows.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return VisibleWindowInfo(id: id, owner: pid, frame: frame, alpha: row[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    static func validate(target: VisibleWindowInfo, display: CGRect, windows: [VisibleWindowInfo]) throws {
        guard display.contains(target.frame),
              let index = windows.firstIndex(where: { $0.id == target.id && $0.owner == target.owner }) else {
            throw VisibleCaptureError.unavailable
        }
        let current = windows[index]
        guard abs(current.frame.minX - target.frame.minX) <= 1,
              abs(current.frame.minY - target.frame.minY) <= 1,
              abs(current.frame.width - target.frame.width) <= 1,
              abs(current.frame.height - target.frame.height) <= 1 else { throw VisibleCaptureError.moved }
        guard current.alpha >= 0.99 else { throw VisibleCaptureError.unavailable }
        for window in windows.prefix(index) where window.alpha > 0.01 {
            let overlap = window.frame.intersection(target.frame)
            if !overlap.isNull && overlap.width * overlap.height > 1 {
                throw VisibleCaptureError.covered
            }
        }
    }

    static func hasPixelVariation(_ image: CGImage) -> Bool {
        let width = 128, height = 160
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var low = [255, 255, 255], high = [0, 0, 0], opaque = 0
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] >= 128 {
            opaque += 1
            for c in 0..<3 { low[c] = min(low[c], Int(pixels[i + c])); high[c] = max(high[c], Int(pixels[i + c])) }
        }
        return opaque > 100 && (0..<3).contains { high[$0] - low[$0] >= 12 }
    }
}
