import CoreGraphics
import Foundation

enum RecordScrollError: LocalizedError {
    case windowGone, cannotFocus, eventUnavailable
    var errorDescription: String? {
        switch self {
        case .windowGone: return "合并聊天记录窗口已关闭或不可见，已停止滚动。请重新打开原记录后重试。"
        case .cannotFocus: return "未能将合并聊天记录置于前台，已停止，避免滚动其他窗口。请保持该记录可见后重试。"
        case .eventUnavailable: return "无法生成滚动事件，请检查聊析的辅助功能权限。"
        }
    }
}

enum RecordScrollMode: String {
    case precise, wheel
}

enum RecordScrollPlan {
    /// Prefer the body gutter instead of the centre, which can be an image/video's nested view.
    static func location(in frame: CGRect, mode: RecordScrollMode) -> CGPoint {
        CGPoint(x: frame.minX + frame.width * (mode == .precise ? 0.86 : 0.66),
                y: frame.minY + frame.height * 0.68)
    }

    static func chunks(for delta: Int32, mode: RecordScrollMode) -> [Int32] {
        guard delta != 0 else { return [] }
        let sign: Int32 = delta > 0 ? 1 : -1
        var remaining = mode == .precise ? abs(Int64(delta)) : max(1, abs(Int64(delta)) / 20)
        let maximum: Int64 = mode == .precise ? 40 : 3
        var result: [Int32] = []
        while remaining > 0 {
            let amount = min(maximum, remaining)
            result.append(sign * Int32(amount)); remaining -= amount
        }
        return result
    }

    static func matchesWindow(id: CGWindowID, owner: pid_t, visible: Bool, frame: CGRect,
                              expectedID: CGWindowID, expectedOwner: pid_t) -> Bool {
        id == expectedID && owner == expectedOwner && visible && !frame.isNull && !frame.isInfinite
            && frame.width >= 200 && frame.height >= 200
    }
}

enum ScrollAdvanceDecision: Equatable {
    case nextPage, confirmedBottom, unconfirmed

    /// A repeated frame alone is never evidence of reaching the end.
    static func decide(original: String, afterDown: [String], afterUp: String?, afterReturn: String?) -> Self {
        if afterDown.contains(where: { $0 != original }) { return .nextPage }
        guard afterDown.count >= 2, let afterUp, afterUp != original, let afterReturn else { return .unconfirmed }
        return afterReturn == original ? .confirmedBottom : .nextPage
    }
}

enum ScrollDiagnostics {
    /// Local metadata only; never writes messages, window titles, clipboard contents or screen images.
    static func record(_ event: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ChatArchive")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("scroll.log")
        let data = Data("\(Date().timeIntervalSince1970) \(event)\n".utf8)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }
}
