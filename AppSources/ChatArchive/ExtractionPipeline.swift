import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

struct ExtractionPipeline {
    let progress: @MainActor @Sendable (String) -> Void
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
        var target = try await captureService.locateWeChatWindow()
        let collector = try AttachmentCollector()
        defer { collector.cleanUp() }

        progress("正在回到记录顶部…")
        var topDigest: String?
        for _ in 0..<60 {
            try Task.checkCancellation()
            target = try await captureService.activateAndScroll(target: target, delta: 1_200)
            let digest = frameDigest(try await captureService.capture(target))
            if digest == topDigest { break }
            topDigest = digest
        }

        var pageLines: [[RecognizedLine]] = []
        var accessibilityPages: [[String]] = []
        var previousDigest: String?
        var reachedBottom = false
        var scrollUnconfirmed = false

        for index in 0..<120 {
            try Task.checkCancellation()
            progress("正在读取第 \(index + 1) 屏…")
            var image = try await captureService.capture(target)
            var digest = frameDigest(image)
            if let previousDigest, digest == previousDigest {
                progress("画面未变化，正在重新定位并重试滚动…")
                var downDigests = [digest]
                target = try await captureService.activateAndScroll(target: target,
                    delta: -Int32(target.window.frame.height * 0.5), mode: .wheel)
                image = try await captureService.capture(target); digest = frameDigest(image)
                downDigests.append(digest)
                if digest == previousDigest {
                    // Prove that scrolling works at this boundary: move up a little, then return down.
                    // If even the probe does not move, preserve current content with an incomplete warning.
                    target = try await captureService.activateAndScroll(target: target, delta: 120)
                    let upDigest = frameDigest(try await captureService.capture(target))
                    target = try await captureService.activateAndScroll(target: target,
                        delta: -Int32(target.window.frame.height * 0.5))
                    image = try await captureService.capture(target); digest = frameDigest(image)
                    let decision = ScrollAdvanceDecision.decide(original: previousDigest, afterDown: downDigests,
                        afterUp: upDigest, afterReturn: digest)
                    ScrollDiagnostics.record("boundary decision=\(decision) pages=\(pageLines.count)")
                    if decision != .nextPage {
                        reachedBottom = decision == .confirmedBottom
                        scrollUnconfirmed = !reachedBottom
                        break
                    }
                }
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

            target = try await captureService.activateAndScroll(target: target, delta: -Int32(target.window.frame.height * 0.5))
        }

        let ocrLines = processor.mergePages(pageLines)
        let accessibilityLines = processor.mergeAccessibilityPages(accessibilityPages)
        let chosen = processor.chooseText(accessibility: accessibilityLines, ocr: ocrLines)
        guard !chosen.lines.isEmpty else { throw ExtractionError.noContent }
        let quoteKeys = processor.quoteKeys(in: pageLines)

        try Task.checkCancellation()
        let fileNames = processor.likelyFileNames(in: chosen.lines)
        var warnings = collector.warnings
        if scrollUnconfirmed { warnings.append("未能确认滚动已到底：已保存当前读取内容，但记录可能不完整。请保持合并记录可见后重试，不要把单页结果当作完整记录。") }
        else if !reachedBottom { warnings.append("已达到 120 屏上限，请检查聊天记录是否完整。") }
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
