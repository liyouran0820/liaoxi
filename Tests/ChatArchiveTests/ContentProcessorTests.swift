import XCTest
@testable import ChatArchive

final class ContentProcessorTests: XCTestCase {
    func testMergesOverlappingOCRPages() {
        let processor = ContentProcessor()
        let pageOne = [
            RecognizedLine(text: "张三", bounds: .zero, confidence: 1),
            RecognizedLine(text: "先安装 Homebrew", bounds: .zero, confidence: 1),
            RecognizedLine(text: "然后打开终端", bounds: .zero, confidence: 1)
        ]
        let pageTwo = [
            RecognizedLine(text: "然后打开终端", bounds: .zero, confidence: 1),
            RecognizedLine(text: "brew install node", bounds: .zero, confidence: 1)
        ]

        XCTAssertEqual(
            processor.mergePages([pageOne, pageTwo]),
            ["张三", "先安装 Homebrew", "然后打开终端", "brew install node"]
        )
    }

    func testPrefersAccessibilityWhenItContainsEnoughText() {
        let result = ContentProcessor().chooseText(
            accessibility: ["这是一段来自辅助功能树的完整聊天正文，能够避免 OCR 对代码和英文命令造成识别错误。"],
            ocr: ["这是一段 OCR 文字", "可能有误"]
        )
        XCTAssertTrue(result.usedAccessibility)
    }

    func testFindsFileCards() {
        let names = ContentProcessor().likelyFileNames(in: ["请查看 项目说明.pdf", "配置 config.yaml"])
        XCTAssertEqual(names, ["项目说明.pdf", "config.yaml"])
    }

    func testFiltersAccessibilityTextThatIsNotVisibleInCapture() {
        let processor = ContentProcessor()
        let ocr = [
            RecognizedLine(text: "然后打开终端", bounds: .zero, confidence: 1),
            RecognizedLine(text: "brew install node", bounds: .zero, confidence: 1)
        ]
        XCTAssertEqual(
            processor.visibleAccessibilityText(["文件传输助手", "然后打开终端", "通讯录"], matching: ocr),
            ["然后打开终端"]
        )
    }

    func testAccessibilitySettingsDeepLink() {
        XCTAssertEqual(
            SystemSettingsService.accessibilityURL.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        XCTAssertEqual(
            SystemSettingsService.legacyAccessibilityURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            SystemSettingsService.screenCaptureURL.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
        XCTAssertEqual(
            SystemSettingsService.legacyScreenCaptureURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testRecognizesMutedAttributedReplyAsQuote() {
        let lines = [
            RecognizedLine(text: "NemoArce", bounds: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.05), confidence: 1, tone: .muted),
            RecognizedLine(text: "2026年8月28日 00:09", bounds: CGRect(x: 0.7, y: 0.8, width: 0.2, height: 0.05), confidence: 1, tone: .muted),
            RecognizedLine(text: "上海的？", bounds: CGRect(x: 0.1, y: 0.65, width: 0.2, height: 0.06), confidence: 1, tone: .primary),
            RecognizedLine(text: "槐序知安：我的计算能力已经被高中三年计算器毁渣了", bounds: CGRect(x: 0.1, y: 0.53, width: 0.7, height: 0.05), confidence: 1, tone: .muted)
        ]

        let keys = ContentProcessor().quoteKeys(in: [lines])
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys.contains("槐序知安我的计算能力已经被高中三年计算器毁渣了"))
    }

    func testMutedTimestampAndSenderAreNotQuotes() {
        let lines = [
            RecognizedLine(text: "NemoArce", bounds: .zero, confidence: 1, tone: .muted),
            RecognizedLine(text: "2026年8月28日 00:09", bounds: .zero, confidence: 1, tone: .muted)
        ]
        XCTAssertTrue(ContentProcessor().quoteKeys(in: [lines]).isEmpty)
    }

    func testMarkdownExporterUsesQuoteBlock() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let report = try MarkdownExporter().export(
            lines: ["这是回复", "张三：这是被引用的原消息"],
            attachments: [],
            fileNames: [],
            quoteKeys: ["张三这是被引用的原消息"],
            pages: 1,
            usedAccessibility: false,
            to: parent
        )
        let markdown = try String(contentsOf: report.markdownURL, encoding: .utf8)
        let styleGuide = "## 内容样式说明（供 LLM 阅读）\n\n"
            + "- **正文样式**：不带引用前缀的普通文本，表示当前消息正文。\n"
            + "- **引用样式**：以 `> ` 开头的 Markdown 引用块，表示微信正文下方灰色的被引用原消息；它是上下文，不是当前发送者的新正文。"
        XCTAssertTrue(markdown.hasPrefix("# 微信合并聊天记录"))
        XCTAssertTrue(markdown.contains(styleGuide))
        XCTAssertLessThan(
            try XCTUnwrap(markdown.range(of: styleGuide)?.lowerBound),
            try XCTUnwrap(markdown.range(of: "## 对话内容")?.lowerBound)
        )
        XCTAssertTrue(markdown.contains("这是回复  \n\n> 张三：这是被引用的原消息"))
    }

    func testSingleFolderPreservesOriginalFilesAndCollisions() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let inputs = parent.appendingPathComponent("inputs")
        let second = inputs.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let names = ["photo #1.png", "video.mp4", "conversation.md", "plan.pdf"]
        let sources = names.enumerated().map { index, name in (inputs.appendingPathComponent(name), Data("original-\(index)".utf8)) }
        for (url, data) in sources { try data.write(to: url) }
        let collision = second.appendingPathComponent("plan.pdf")
        try Data("another original".utf8).write(to: collision)
        let report = try MarkdownExporter().export(lines: ["分享附件"], attachments: [], fileNames: ["plan.pdf"],
                                                 quoteKeys: [], pages: 1, usedAccessibility: false,
                                                 sourceFiles: sources.map(\.0) + [collision, sources[0].0], to: parent)
        let folder = report.markdownURL.deletingLastPathComponent()
        let outputNames = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(Set(outputNames), Set(["conversation.md", "photo #1.png", "video.mp4", "conversation-2.md", "plan.pdf", "plan-2.pdf"]))
        XCTAssertFalse(outputNames.contains("attachments"))
        for (url, data) in sources {
            let name = url.lastPathComponent == "conversation.md" ? "conversation-2.md" : url.lastPathComponent
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), data)
        }
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("(photo%20%231.png)"))
        XCTAssertTrue(md.contains("(video.mp4)"))
        XCTAssertEqual(report.imageCount, 1)
        XCTAssertEqual(report.videoCount, 1)
        XCTAssertEqual(report.fileCount, 3)
        XCTAssertEqual(report.missingAttachmentCount, 0)
        let moved = parent.appendingPathComponent("移动后的记录")
        try FileManager.default.moveItem(at: folder, to: moved)
        let regex = try NSRegularExpression(pattern: #"\]\(([^)]+)\)"#)
        for match in regex.matches(in: md, range: NSRange(md.startIndex..<md.endIndex, in: md)) {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: md))
            let name = try XCTUnwrap(String(md[range]).removingPercentEncoding)
            XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(name).path))
        }
    }

    func testMissingSourceIsExplicitAndNotCounted() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let report = try MarkdownExporter().export(lines: ["missing.pdf"], attachments: [], fileNames: ["missing.pdf"],
                                                 quoteKeys: [], pages: 1, usedAccessibility: false,
                                                 sourceFiles: [parent.appendingPathComponent("missing.pdf")], to: parent)
        XCTAssertEqual(report.fileCount, 0)
        XCTAssertGreaterThan(report.missingAttachmentCount, 0)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("未保存的附件"))
    }
}
