import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

struct ExtractionPipeline {
    let progress: @Sendable (String) -> Void
    private let captureService = WindowCaptureService()
    private let ocrService = OCRService()
    private let accessibilityService = AccessibilityTextService()
    private let processor = ContentProcessor()
    private let exporter = MarkdownExporter()

    @MainActor
    func run(in outputDirectory: URL, sourceFiles: [URL] = []) async throws -> ExtractionReport {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw ExtractionError.permissionMissing
        }
        let target = try await captureService.locateWeChatWindow()
        let collector = try AttachmentCollector()
        defer { collector.cleanUp() }

        progress("正在回到记录顶部…")
        var topDigest: String?
        for _ in 0..<60 {
            try Task.checkCancellation()
            await captureService.activateAndScroll(target: target, delta: 1_800)
            let digest = frameDigest(try await captureService.capture(target))
            if digest == topDigest { break }
            topDigest = digest
        }

        var pageLines: [[RecognizedLine]] = []
        var accessibilityPages: [[String]] = []
        var previousDigest: String?
        var reachedBottom = false

        for index in 0..<120 {
            try Task.checkCancellation()
            progress("正在读取第 \(index + 1) 屏…")
            let image = try await captureService.capture(target)
            let digest = frameDigest(image)
            if digest == previousDigest {
                reachedBottom = true
                break
            }
            previousDigest = digest

            let lines = try await ocrService.recognize(image)
            pageLines.append(lines)
            let accessibilityText = accessibilityService.visibleText(
                processID: target.application.processID,
                matching: target.window.frame
            )
            accessibilityPages.append(processor.visibleAccessibilityText(accessibilityText, matching: lines))

            progress("正在保存第 \(index + 1) 屏的附件…")
            try await collector.collect(target: target, lines: lines, regions: processor.mediaRegions(in: image))

            await captureService.activateAndScroll(target: target, delta: -Int32(target.window.frame.height * 0.55))
        }

        let ocrLines = processor.mergePages(pageLines)
        let accessibilityLines = processor.mergeAccessibilityPages(accessibilityPages)
        let chosen = processor.chooseText(accessibility: accessibilityLines, ocr: ocrLines)
        guard !chosen.lines.isEmpty else { throw ExtractionError.noContent }
        let quoteKeys = processor.quoteKeys(in: pageLines)

        try Task.checkCancellation()
        let fileNames = processor.likelyFileNames(in: chosen.lines)
        var warnings = collector.warnings
        if !reachedBottom { warnings.append("已达到 120 屏上限，请检查聊天记录是否完整。") }
        if collector.attemptedCount > 0 && collector.files.isEmpty {
            warnings.append("本次没有取得附件原文件；微信未暴露另存或复制操作时，请手动另存后使用“补充附件”。")
        }

        progress("正在生成 Markdown…")
        try Task.checkCancellation()
        return try exporter.export(
            lines: chosen.lines,
            attachments: [],
            fileNames: fileNames,
            quoteKeys: quoteKeys,
            pages: pageLines.count,
            usedAccessibility: chosen.usedAccessibility,
            sourceFiles: sourceFiles + collector.files,
            attachmentWarnings: warnings,
            to: outputDirectory
        )
    }

    private func frameDigest(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data else { return UUID().uuidString }
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }
}
