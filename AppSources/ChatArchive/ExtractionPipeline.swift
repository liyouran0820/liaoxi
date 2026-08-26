import ApplicationServices
import CoreGraphics
import Foundation

struct ExtractionPipeline {
    let progress: @Sendable (String) -> Void
    private let captureService = WindowCaptureService()
    private let ocrService = OCRService()
    private let accessibilityService = AccessibilityTextService()
    private let processor = ContentProcessor()
    private let exporter = MarkdownExporter()

    func run(in outputDirectory: URL) async throws -> ExtractionReport {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw ExtractionError.permissionMissing
        }
        let target = try await captureService.locateWeChatWindow()

        progress("正在回到记录顶部…")
        for _ in 0..<10 {
            try Task.checkCancellation()
            await captureService.activateAndScroll(target: target, delta: 1_800)
        }

        var pages: [PageCapture] = []
        var accessibilityPages: [[String]] = []
        var previousHash: UInt64?
        var repeatedFrames = 0

        for index in 0..<40 {
            try Task.checkCancellation()
            progress("正在读取第 \(index + 1) 屏…")
            let image = try await captureService.capture(target)
            let hash = compactHash(image)
            if let previousHash, (previousHash ^ hash).nonzeroBitCount <= 2 {
                repeatedFrames += 1
                if repeatedFrames >= 2 { break }
            } else {
                repeatedFrames = 0
            }
            previousHash = hash

            let lines = try await ocrService.recognize(image)
            pages.append(PageCapture(image: image, lines: lines))
            let accessibilityText = accessibilityService.visibleText(
                processID: target.application.processID,
                matching: target.window.frame
            )
            accessibilityPages.append(processor.visibleAccessibilityText(accessibilityText, matching: lines))

            await captureService.activateAndScroll(target: target, delta: -760)
        }

        let ocrLines = processor.mergePages(pages.map(\.lines))
        let accessibilityLines = processor.mergeAccessibilityPages(accessibilityPages)
        let chosen = processor.chooseText(accessibility: accessibilityLines, ocr: ocrLines)
        guard !chosen.lines.isEmpty else { throw ExtractionError.noContent }

        try Task.checkCancellation()
        progress("正在裁切记录中的图片…")
        let attachments = try await processor.extractAttachments(from: pages)
        let fileNames = processor.likelyFileNames(in: chosen.lines)

        progress("正在生成 Markdown…")
        try Task.checkCancellation()
        return try exporter.export(
            lines: chosen.lines,
            attachments: attachments,
            fileNames: fileNames,
            pages: pages.count,
            usedAccessibility: chosen.usedAccessibility,
            to: outputDirectory
        )
    }

    private func compactHash(_ image: CGImage) -> UInt64 {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let values = stride(from: 0, to: pixels.count, by: 4).map { index in
            (Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3
        }
        let mean = values.reduce(0, +) / max(values.count, 1)
        return values.enumerated().reduce(UInt64.zero) { partial, item in
            item.element >= mean ? partial | (UInt64(1) << UInt64(item.offset)) : partial
        }
    }
}
