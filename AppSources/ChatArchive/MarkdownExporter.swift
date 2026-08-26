import AppKit
import Foundation

struct MarkdownExporter {
    func export(
        lines: [String],
        attachments: [ExtractedAttachment],
        fileNames: [String],
        pages: Int,
        usedAccessibility: Bool,
        to parentDirectory: URL
    ) throws -> ExtractionReport {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = parentDirectory.appendingPathComponent("微信聊天记录-\(formatter.string(from: Date()))", isDirectory: true)
        let attachmentsFolder = folder.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsFolder, withIntermediateDirectories: true)

        for attachment in attachments {
            let representation = NSBitmapImageRep(cgImage: attachment.image)
            guard let data = representation.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: attachmentsFolder.appendingPathComponent(attachment.fileName), options: .atomic)
        }

        let markdownURL = folder.appendingPathComponent("conversation.md")
        let markdown = makeMarkdown(lines: lines, attachments: attachments, fileNames: fileNames, usedAccessibility: usedAccessibility)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)

        let reportURL = folder.appendingPathComponent("extraction-report.json")
        let reportObject: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "textSource": usedAccessibility ? "accessibility" : "vision-ocr",
            "pageCount": pages,
            "textLineCount": lines.count,
            "imageCount": attachments.count,
            "detectedFileNames": fileNames,
            "limitations": [
                "图片由界面矩形与文字覆盖率启发式识别，请人工抽查。",
                "文件卡片只记录文件名，不包含原文件。"
            ]
        ]
        let reportData = try JSONSerialization.data(withJSONObject: reportObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try reportData.write(to: reportURL, options: .atomic)

        return ExtractionReport(
            markdownURL: markdownURL,
            reportURL: reportURL,
            textLineCount: lines.count,
            imageCount: attachments.count,
            pageCount: pages,
            usedAccessibilityText: usedAccessibility
        )
    }

    private func makeMarkdown(
        lines: [String],
        attachments: [ExtractedAttachment],
        fileNames: [String],
        usedAccessibility: Bool
    ) -> String {
        var result = "# 微信合并聊天记录\n\n"
        result += "> 提取时间：\(formattedDate())  \n"
        result += "> 文字来源：\(usedAccessibility ? "macOS 辅助功能原文" : "Apple Vision 本地 OCR")\n\n"
        result += "## 对话内容\n\n"
        for line in lines {
            result += escapeMarkdown(line) + "  \n"
        }

        if !attachments.isEmpty {
            result += "\n## 图片\n\n"
            for (index, attachment) in attachments.enumerated() {
                result += "![图片 \(index + 1)](attachments/\(attachment.fileName))\n\n"
            }
        }

        if !fileNames.isEmpty {
            result += "## 文件卡片\n\n"
            for name in fileNames {
                result += "- \(escapeMarkdown(name))（仅识别到文件名，未提取原文件）\n"
            }
            result += "\n"
        }

        return result
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
