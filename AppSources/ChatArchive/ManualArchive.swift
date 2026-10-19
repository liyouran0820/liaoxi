import Foundation

struct ManualAttachment: Equatable, Sendable {
    let id: Int
    let source: URL
    var token: String { "[[\(ArchiveFiles.kind(source)) \(id)：\(source.lastPathComponent)]]" }
}

enum ManualDraft {
    static func inserting(_ content: String, into text: String, selection: NSRange, block: Bool = false) -> (text: String, selection: NSRange) {
        let range = Range(selection, in: text) ?? text.endIndex..<text.endIndex
        let before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
        var insertion = content
        if block {
            if !before.isEmpty && !before.hasSuffix("\n") { insertion = "\n\n" + insertion }
            if !after.isEmpty && !after.hasPrefix("\n") { insertion += "\n\n" }
            else { insertion += "\n" }
        }
        return (before + insertion + after, NSRange(location: before.utf16.count + insertion.utf16.count, length: 0))
    }
}

enum ManualArchiveError: LocalizedError {
    case empty, invalidDirectory, duplicateIDs
    var errorDescription: String? {
        switch self {
        case .empty: return "请先粘贴聊天文字或添加附件。"
        case .invalidDirectory: return "请选择有效的导出文件夹。"
        case .duplicateIDs: return "附件编号重复，请重新添加附件。"
        }
    }
}

/// The manual route performs file IO only: no window APIs, OCR, accessibility or clipboard reads.
struct ManualMarkdownExporter {
    func export(draft: String, attachments: [ManualAttachment], to parent: URL) throws -> ExtractionReport {
        try Task.checkCancellation()
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { throw ManualArchiveError.empty }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else { throw ManualArchiveError.invalidDirectory }
        guard Set(attachments.map(\.id)).count == attachments.count else { throw ManualArchiveError.duplicateIDs }
        let workspace = try ArchiveWorkspace(parent: parent)
        var retained: [Int: URL] = [:], hashes: [String: URL] = [:]
        var saved: [URL] = [], warnings: [String] = []
        let sourceText = attachments.reduce(draft) { $0.replacingOccurrences(of: $1.token, with: "") }
        let lineCount = sourceText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count

        func label(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        }
        func write(status: String?) throws {
            var body = draft
            for attachment in attachments {
                let replacement: String
                if let file = retained[attachment.id] {
                    replacement = "[\(ArchiveFiles.kind(file))：\(label(file.lastPathComponent))](\(ArchiveFiles.relativeLink(file.lastPathComponent)))"
                } else { replacement = "[附件未保存：\(label(attachment.source.lastPathComponent))]" }
                body = body.replacingOccurrences(of: attachment.token, with: replacement)
            }
            var md = "# 微信聊天记录\n\n整理时间：\(Date().formatted(date: .numeric, time: .standard))  \n文字来源：用户手动复制粘贴（未进行 OCR）\n\n"
            if let status { md += "状态：\(status)\n\n" }
            md += "## 内容样式说明（供 LLM 阅读）\n\n"
            md += "- **正文样式**：以下内容由用户粘贴，保留原有文字、换行与 Markdown，不自动推断发言者，也不删除重复消息。\n"
            md += "- **引用样式**：以 `> ` 开头的内容是用户标记的引用；粘贴为纯文本后不根据微信颜色猜测引用。\n"
            md += "- **附件样式**：正文中的链接位于用户手动插入的位置，文件名对应本目录实际文件；照片 / 视频不识别文字。文末仅为索引，不是新消息。\n\n"
            md += "## 对话内容\n\n" + body + "\n\n## 附件索引\n\n"
            if saved.isEmpty { md += "未添加附件。\n" }
            for file in saved {
                let located = attachments.contains { retained[$0.id] == file && draft.contains($0.token) }
                md += "[\(ArchiveFiles.kind(file))：\(label(file.lastPathComponent))](\(ArchiveFiles.relativeLink(file.lastPathComponent)))"
                    + (located ? "" : " — 未插入正文") + "\n\n"
            }
            if !warnings.isEmpty { md += "## 附件提示\n\n" + warnings.map { "- " + $0 }.joined(separator: "\n") + "\n\n" }
            let images = saved.filter { ArchiveFiles.kind($0) == "照片" }.count
            let videos = saved.filter { ArchiveFiles.kind($0) == "视频" }.count
            md += "## 整理信息\n\n手动整理 \(lineCount) 行文字；保存 \(images) 张照片、\(videos) 个视频、\(saved.count - images - videos) 个文件。\n"
            try md.write(to: workspace.markdownURL, atomically: true, encoding: .utf8)
        }

        do {
            // Preserve the pasted text immediately, even if a large attachment later fails or is cancelled.
            try write(status: "正在整理，附件尚未全部保存。")
            for attachment in attachments {
                try Task.checkCancellation()
                do {
                    let values = try attachment.source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    let digest = try ArchiveFiles.digest(attachment.source)
                    if let first = hashes[digest] { retained[attachment.id] = first; continue }
                    let destination = ArchiveFiles.uniqueURL(in: workspace.directory, name: attachment.source.lastPathComponent)
                    do {
                        try FileManager.default.copyItem(at: attachment.source, to: destination)
                        guard try ArchiveFiles.digest(destination) == digest else { throw CocoaError(.fileReadCorruptFile) }
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        throw error
                    }
                    retained[attachment.id] = destination
                    hashes[digest] = destination
                    saved.append(destination)
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.append("\(attachment.source.lastPathComponent)：未保存（\(error.localizedDescription)）。") }
            }
            try Task.checkCancellation()
            try write(status: nil)
            let images = saved.filter { ArchiveFiles.kind($0) == "照片" }.count
            let videos = saved.filter { ArchiveFiles.kind($0) == "视频" }.count
            return ExtractionReport(markdownURL: workspace.markdownURL, reportURL: workspace.markdownURL,
                textLineCount: lineCount, imageCount: images, pageCount: 0, usedAccessibilityText: false,
                fileCount: saved.count - images - videos, videoCount: videos, missingAttachmentCount: warnings.count)
        } catch {
            try? write(status: error is CancellationError ? "已停止，粘贴文字及已保存附件保留。" : "整理失败：\(error.localizedDescription)")
            throw error
        }
    }
}
