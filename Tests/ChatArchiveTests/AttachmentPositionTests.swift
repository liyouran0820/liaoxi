import XCTest
@testable import ChatArchive

final class AttachmentPositionTests: XCTestCase {
    func testResolverNeverChangesTextAndRejectsAmbiguousContext() {
        let lines = ["Alice", "时间A", "正文A", "Bob", "时间B", "正文B"]
        let original = lines
        let photo = URL(fileURLWithPath: "/tmp/photo.jpg")
        let position = AttachmentPosition(file: photo, before: Array(lines.prefix(3)), after: Array(lines.suffix(3)))
        XCTAssertEqual(AttachmentPositionResolver.resolve([position, position], in: lines), [3: [photo]])
        XCTAssertEqual(lines, original)
        let ambiguous = AttachmentPosition(file: photo, before: ["Alice", "时间A"], after: [])
        XCTAssertTrue(AttachmentPositionResolver.resolve([ambiguous], in: ["Alice", "时间A", "Alice", "时间A"]).isEmpty)
    }

    func testExporterKeepsEveryOriginalMessageAndQuote() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let photo = parent.appendingPathComponent("photo.jpg")
        try Data("photo".utf8).write(to: photo)
        let lines = ["Alice", "2026年10月19日 01:00", "照片前的消息", "Bob", "2026年10月19日 01:01", "照片后的消息", "笑死我了", "再次回复", "笑死我了", "张三：引用内容"]
        let position = AttachmentPosition(file: photo, before: Array(lines.prefix(3)), after: Array(lines.dropFirst(3).prefix(6)))
        let report = try MarkdownExporter().export(lines: lines, attachments: [], fileNames: [], quoteKeys: ["张三引用内容"],
            pages: 1, usedAccessibility: false, sourceFiles: [photo], attachmentPositions: [position], to: parent)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        let body = md.components(separatedBy: "## 对话内容\n\n")[1].components(separatedBy: "## 附件")[0]
        let extracted = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[照片：") }.map { $0.hasPrefix("> ") ? String($0.dropFirst(2)) : $0 }
        XCTAssertEqual(extracted, lines)
        XCTAssertEqual(report.textLineCount, lines.count)
        XCTAssertTrue(body.contains("照片前的消息  \n\n[照片：photo.jpg](photo.jpg)  \n\nBob"))
        XCTAssertTrue(body.contains("> 张三：引用内容"))
        XCTAssertFalse(md.contains("[[liaoxi-attachment:"))
    }

    func testContentAliasesCollapseOnlyAtTheSameMessagePosition() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let photo = parent.appendingPathComponent("photo.jpg"), alias = parent.appendingPathComponent("alias.jpg")
        for file in [photo, alias] { try Data("identical photo".utf8).write(to: file) }
        let lines = ["Alice", "时间A", "消息A", "Bob", "时间B", "消息B"]
        let positions = [AttachmentPosition(file: photo, before: Array(lines.prefix(3)), after: Array(lines.suffix(3))),
                         AttachmentPosition(file: alias, before: Array(lines.prefix(3)), after: Array(lines.suffix(3))),
                         AttachmentPosition(file: photo, before: lines, after: [])]
        let report = try MarkdownExporter().export(lines: lines, attachments: [], fileNames: [], quoteKeys: [], pages: 2,
            usedAccessibility: false, sourceFiles: [photo, alias], attachmentPositions: positions, to: parent)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        let body = md.components(separatedBy: "## 对话内容\n\n")[1].components(separatedBy: "## 附件")[0]
        XCTAssertEqual(body.components(separatedBy: "[照片：photo.jpg]").count - 1, 2)
        XCTAssertFalse(md.contains("alias.jpg"))
        XCTAssertEqual(report.imageCount, 1)
        XCTAssertEqual(report.textLineCount, lines.count)
    }

    func testCollisionLinksAndUnlocatedFilesAreExplicit() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let other = parent.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let first = parent.appendingPathComponent("photo.jpg"), second = other.appendingPathComponent("photo.jpg")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        let lines = ["Alice", "时间A", "正文A", "正文B"]
        let position = AttachmentPosition(file: second, before: Array(lines.prefix(3)), after: Array(lines.suffix(1)))
        let report = try MarkdownExporter().export(lines: lines, attachments: [], fileNames: [], quoteKeys: [], pages: 1,
            usedAccessibility: false, sourceFiles: [first, second], attachmentPositions: [position], to: parent)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("[照片：photo-2.jpg](photo-2.jpg)  \n\n正文B"))
        XCTAssertTrue(md.contains("[照片：photo.jpg](photo.jpg) — 聊天位置未确定"))
    }
}
