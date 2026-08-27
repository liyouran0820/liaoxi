import CoreGraphics
import Foundation

enum TextTone: Equatable {
    case primary
    case muted
    case unknown
}

struct RecognizedLine: Equatable {
    let text: String
    let bounds: CGRect
    let confidence: Float
    let tone: TextTone

    init(text: String, bounds: CGRect, confidence: Float, tone: TextTone = .unknown) {
        self.text = text
        self.bounds = bounds
        self.confidence = confidence
        self.tone = tone
    }
}

struct PageCapture {
    let image: CGImage
    let lines: [RecognizedLine]
}

struct ExtractedAttachment {
    let fileName: String
    let image: CGImage
    let hash: UInt64
}

struct ExtractionReport: Equatable {
    let markdownURL: URL
    let reportURL: URL
    let textLineCount: Int
    let imageCount: Int
    let pageCount: Int
    let usedAccessibilityText: Bool
}

enum ExtractionError: LocalizedError {
    case weChatNotRunning
    case noSuitableWindow
    case permissionMissing
    case captureFailed
    case noContent

    var errorDescription: String? {
        switch self {
        case .weChatNotRunning:
            return "没有发现正在运行的微信。请先打开微信合并聊天记录。"
        case .noSuitableWindow:
            return "没有找到可提取的微信窗口。请打开合并聊天记录卡片并保持窗口可见。"
        case .permissionMissing:
            return "权限尚未生效。请在系统设置中允许后重新打开聊析。"
        case .captureFailed:
            return "微信窗口捕获失败。请确认窗口未最小化且屏幕录制权限已经生效。"
        case .noContent:
            return "没有识别到聊天内容。请把合并聊天记录滚动到内容区域后重试。"
        }
    }
}
