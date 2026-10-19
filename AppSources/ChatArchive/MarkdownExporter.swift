import AppKit
import Foundation

struct MarkdownExporter {
    func export(
        lines: [String],
        attachments: [ExtractedAttachment],
        fileNames: [String],
        quoteKeys: Set<String>,
        pages: Int,
        usedAccessibility: Bool,
        sourceFiles: [URL] = [],
        attachmentWarnings: [String] = [],
        to parentDirectory: URL
    ) throws -> ExtractionReport {
        let manager = FileManager.default
        let staging = parentDirectory.appendingPathComponent(".聊析-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? manager.removeItem(at: staging) } }
        var saved: [(name: String, kind: String, original: Bool)] = []
        var warnings = attachmentWarnings
        var hashes = Set<String>()
        var savedOriginalNames = Set<String>()
        try Data().write(to: staging.appendingPathComponent("conversation.md"), options: .withoutOverwriting)
        for source in sourceFiles {
            try Task.checkCancellation()
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                    warnings.append("\(source.lastPathComponent)：文件为空、不可读或是链接，未保存。")
                    continue
                }
                let digest = try ArchiveFiles.digest(source)
                if hashes.contains(digest) {
                    savedOriginalNames.insert(source.lastPathComponent.lowercased())
                    continue
                }
                let destination = ArchiveFiles.uniqueURL(in: staging, name: source.lastPathComponent)
                do {
                    try manager.copyItem(at: source, to: destination)
                    guard try ArchiveFiles.digest(destination) == digest else { throw CocoaError(.fileReadCorruptFile) }
                } catch {
                    try? manager.removeItem(at: destination)
                    throw error
                }
                hashes.insert(digest)
                savedOriginalNames.insert(source.lastPathComponent.lowercased())
                saved.append((destination.lastPathComponent, ArchiveFiles.kind(source), true))
            } catch {
                warnings.append("\(source.lastPathComponent)：未能保存原文件（\(error.localizedDescription)）。")
            }
        }

        for attachment in attachments {
            try Task.checkCancellation()
            let representation = NSBitmapImageRep(cgImage: attachment.image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                warnings.append("\(attachment.fileName)：未能编码界面预览。")
                continue
            }
            let url = ArchiveFiles.uniqueURL(in: staging, name: "preview-" + attachment.fileName)
            try data.write(to: url, options: .withoutOverwriting)
            saved.append((url.lastPathComponent, "界面预览（非原图）", false))
        }

        let missing = fileNames.filter { !savedOriginalNames.contains($0.lowercased()) }
        warnings += missing.map { "\($0)：检测到文件卡片，未取得原文件。可在微信另存后使用“补充附件”。" }

        var markdown = "# 微信合并聊天记录\n\n"
        markdown += "提取时间：\(Date().formatted(date: .numeric, time: .standard))  \n"
        markdown += "文字来源：\(usedAccessibility ? "macOS 辅助功能原文" : "Apple Vision 本地 OCR")\n\n"
        markdown += "## 内容样式说明（供 LLM 阅读）\n\n"
        markdown += "- **正文样式**：不带引用前缀的普通文本，表示当前消息正文。\n"
        markdown += "- **引用样式**：以 `> ` 开头的 Markdown 引用块，表示微信正文下方灰色的被引用原消息；它是上下文，不是当前发送者的新正文。\n"
        markdown += "- **附件样式**：图片使用图片链接，视频和文档使用文件链接，路径相对于本 Markdown。标为“界面预览”的图片仅用于辅助阅读，不能代替原附件。\n"
        markdown += "- **缺失附件**：见文末“未保存的附件”；未下载成功、过期或未选择的文件不视为已保存。\n\n"
        markdown += "## 对话内容\n\n"
        var wasQuote = false
        for line in lines {
            let isQuote = quoteKeys.contains(key(line))
            if wasQuote != isQuote { markdown += "\n" }
            markdown += (isQuote ? "> " : "") + escaped(line) + "  \n"
            wasQuote = isQuote
        }
        markdown += "\n## 附件\n\n"
        if saved.isEmpty { markdown += "本次未取得附件原文件。\n\n" }
        for file in saved {
            let link = ArchiveFiles.relativeLink(file.name)
            let label = escaped(file.name)
            if file.kind == "照片" || !file.original {
                markdown += "![\(label)](\(link))\n\n"
            } else {
                markdown += "[\(label)](\(link))\n\n"
            }
            markdown += "类型：\(file.kind)\n\n"
        }
        if !warnings.isEmpty {
            markdown += "## 未保存的附件 / 提取提示\n\n"
            for warning in warnings { markdown += "- \(escaped(warning))\n" }
            markdown += "\n"
        }
        let originalImages = saved.filter { $0.original && $0.kind == "照片" }.count
        let videos = saved.filter { $0.kind == "视频" }.count
        let documents = saved.filter { $0.kind == "文档 / 文件" }.count
        markdown += "## 提取信息\n\n读取 \(pages) 屏，\(lines.count) 行文字；保存 \(originalImages) 张照片、\(videos) 个视频、\(documents) 个文件。\n"
        try markdown.write(to: staging.appendingPathComponent("conversation.md"), atomically: true, encoding: .utf8)
        try Task.checkCancellation()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = ArchiveFiles.uniqueURL(in: parentDirectory, name: "微信聊天记录-\(formatter.string(from: Date()))")
        try manager.moveItem(at: staging, to: folder)
        committed = true
        let md = folder.appendingPathComponent("conversation.md")
        return ExtractionReport(markdownURL: md, reportURL: md, textLineCount: lines.count,
                                imageCount: originalImages, pageCount: pages, usedAccessibilityText: usedAccessibility,
                                fileCount: documents, videoCount: videos, missingAttachmentCount: warnings.count)
    }

    private func key(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation } }

    private func escaped(_ value: String) -> String {
        var text = value
        for character in ["\\", "*", "_", "`", "[", "]", "<", ">", "#"] {
            text = text.replacingOccurrences(of: character, with: "\\" + character)
        }
        return text
    }
}
