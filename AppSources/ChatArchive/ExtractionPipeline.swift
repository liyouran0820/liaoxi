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
        let target = try await captureService.locateWeChatWindow()
        CaptureDiagnostics.record("start pid=\(target.application.processID) window=\(target.window.windowID) frame=\(target.window.frame)")
        let workspace = try ArchiveWorkspace(parent: outputDirectory)
        let collector = AttachmentCollector(directory: workspace.directory)
        var completed = false
        defer {
            if !completed { workspace.writeIncomplete("提取未完成或已停止，已保存的附件保留在本目录。") }
        }

        progress("正在回到记录顶部…")
        var topDigest: String?
        for _ in 0..<60 {
            try Task.checkCancellation()
            try await captureService.activateAndScroll(target: target, delta: 1_800)
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

            let detector = MediaRegionDetector()
            let mediaRegions = detector.regions(in: image)
            CaptureDiagnostics.record("page=\(index) regions=\(mediaRegions.count) dimensions=\(image.width)x\(image.height)")
            let textImage = detector.masking(image, regions: mediaRegions)
            let lines = try await ocrService.recognize(textImage)
            pageLines.append(lines)
            let accessibilityText = accessibilityService.visibleText(
                processID: target.application.processID,
                matching: target.window.frame
            )
            accessibilityPages.append(processor.visibleAccessibilityText(accessibilityText, matching: lines))

            progress("正在保存第 \(index + 1) 屏的附件…")
            try await collector.collect(target: target, lines: lines, regions: mediaRegions)

            try await captureService.activateAndScroll(target: target, delta: -Int32(target.window.frame.height * 0.55))
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
        let report = try exporter.export(
            lines: chosen.lines,
            attachments: [],
            fileNames: fileNames,
            quoteKeys: quoteKeys,
            pages: pageLines.count,
            usedAccessibility: chosen.usedAccessibility,
            sourceFiles: sourceFiles + collector.files,
            attachmentWarnings: warnings,
            existingDirectory: workspace.directory,
            to: outputDirectory
        )
        completed = true
        return report
    }

    private func frameDigest(_ image: CGImage) -> String {
        guard let data = image.dataProvider?.data else { return UUID().uuidString }
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }
}
