import XCTest
import CoreGraphics
@testable import ChatArchive

final class AttachmentTimelineTests: XCTestCase {
    func testMediaOccupiesItsMessagePositionWithoutOCR() {
        let file = URL(fileURLWithPath: "/tmp/photo.jpg")
        let image = PositionedAttachment(file: file, bounds: CGRect(x: 0.1, y: 0.55, width: 0.3, height: 0.2))
        let secondOccurrence = PositionedAttachment(file: file, bounds: CGRect(x: 0.1, y: 0.15, width: 0.3, height: 0.2))
        let lines = [RecognizedLine(text: "Alice", bounds: CGRect(x: 0.1, y: 0.9, width: 0.2, height: 0.02), confidence: 1),
                     RecognizedLine(text: "2026年10月19日 01:00", bounds: CGRect(x: 0.5, y: 0.9, width: 0.4, height: 0.02), confidence: 1),
                     RecognizedLine(text: "下一条消息", bounds: CGRect(x: 0.1, y: 0.45, width: 0.3, height: 0.02), confidence: 1)]
        let result = AttachmentTimeline.inserting([image, image, secondOccurrence], into: lines)
        XCTAssertEqual(result.map(\.text), [lines[0].text, lines[1].text, image.marker, lines[2].text, image.marker])
    }

    func testAXProjectionRequiresUniqueContext() {
        let marker = PositionedAttachment(file: URL(fileURLWithPath: "/tmp/image.jpg"), bounds: .zero).marker
        let timeline = ["Alice", "时间A", marker, "Bob", "时间B", "正文"]
        let text = timeline.filter { !AttachmentTimeline.isMarker($0) }
        XCTAssertEqual(AttachmentTimeline.projecting(timeline, onto: text), timeline)
        XCTAssertEqual(AttachmentTimeline.projecting(["Alice", "时间A", marker], onto: ["Alice", "时间A", "Alice", "时间A"]),
                       ["Alice", "时间A", "Alice", "时间A"])
    }

    func testMediaOverlapsOnceButRealRepeatedImageKeepsBothPositions() {
        let marker = PositionedAttachment(file: URL(fileURLWithPath: "/tmp/image.jpg"), bounds: .zero).marker
        let first = ["Alice01", "2026年10月19日 01:00", marker]
        let overlap = ["Alice0l", "2026年10月19日01:00", marker, "Bob", "2026年10月19日 01:01", marker]
        XCTAssertEqual(PageOverlap.merge(first, overlap), first + Array(overlap.suffix(3)))
    }

    func testInlineLinksResolveAfterCollisionAndContentDeduplication() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let a = parent.appendingPathComponent("a"), b = parent.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
        let first = a.appendingPathComponent("photo.jpg"), second = b.appendingPathComponent("photo.jpg"), duplicate = b.appendingPathComponent("duplicate.jpg")
        try Data("first image".utf8).write(to: first)
        try Data("second image".utf8).write(to: second)
        try Data("first image".utf8).write(to: duplicate)
        let m1 = PositionedAttachment(file: second, bounds: .zero).marker
        let m2 = PositionedAttachment(file: duplicate, bounds: .zero).marker
        let report = try MarkdownExporter().export(lines: ["第一条消息", m1, "第二条消息", m2, "第三条消息", m2],
            attachments: [], fileNames: [], quoteKeys: [], pages: 1, usedAccessibility: false,
            sourceFiles: [first, second, duplicate], attachmentReferences: [m1: second, m2: duplicate], to: parent)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        let body = try XCTUnwrap(md.components(separatedBy: "## 对话内容\n\n").last?.components(separatedBy: "## 附件").first)
        XCTAssertTrue(body.contains("第一条消息  \n\n[照片：photo-2.jpg](photo-2.jpg)"))
        XCTAssertTrue(body.contains("第二条消息  \n\n[照片：photo.jpg](photo.jpg)"))
        XCTAssertEqual(body.components(separatedBy: "[照片：photo.jpg]").count - 1, 2)
        XCTAssertFalse(md.contains("[[liaoxi-attachment:"))
        XCTAssertFalse(md.contains("duplicate.jpg"))
        XCTAssertFalse(md.contains("聊天位置未确定"))
        XCTAssertEqual(report.imageCount, 2)
        XCTAssertEqual(report.textLineCount, 3)
    }

    func testUnlocatedSupplementAndMissingFileAreNotInventedPositions() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("manual.mp4"), missing = parent.appendingPathComponent("missing.pdf")
        try Data("video".utf8).write(to: file)
        let marker = PositionedAttachment(file: missing, bounds: .zero).marker
        let report = try MarkdownExporter().export(lines: ["正文", marker], attachments: [], fileNames: [], quoteKeys: [],
            pages: 1, usedAccessibility: false, sourceFiles: [file, missing], attachmentReferences: [marker: missing], to: parent)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("[附件未保存：missing.pdf]"))
        XCTAssertTrue(md.contains("[视频：manual.mp4](manual.mp4) — 聊天位置未确定"))
        XCTAssertFalse(md.contains("(missing.pdf)"))
        XCTAssertEqual(report.textLineCount, 1)
    }
}
