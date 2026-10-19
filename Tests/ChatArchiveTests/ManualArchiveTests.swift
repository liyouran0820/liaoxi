import XCTest
@testable import ChatArchive

final class ManualArchiveTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ManualArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testPastePreservesExactBodyIncludingRepeatQuoteAndCode() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let text = "A：你好🙂\n\n> 引用\n```sh\n echo hello\n```\n重复\n重复"
        let report = try ManualMarkdownExporter().export(draft: text, attachments: [], to: root)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("## 对话内容\n\n" + text + "\n\n## 附件索引"))
        XCTAssertEqual(report.pageCount, 0)
        XCTAssertFalse(report.usedAccessibilityText)
        XCTAssertEqual(report.markdownURL.deletingPathExtension().lastPathComponent, report.markdownURL.deletingLastPathComponent().lastPathComponent)
    }

    func testInlineAttachmentsAreCopiedDeduplicatedAndCollisionSafe() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let photo = root.appendingPathComponent("photo.jpg"), alias = root.appendingPathComponent("alias.jpg")
        let second = other.appendingPathComponent("photo.jpg"), video = root.appendingPathComponent("movie.mp4")
        for file in [photo, alias] { try Data("same photo".utf8).write(to: file) }
        try Data("different photo".utf8).write(to: second)
        try Data("video".utf8).write(to: video)
        let entries = [photo, alias, second, video].enumerated().map { ManualAttachment(id: $0.offset + 1, source: $0.element) }
        let draft = "A\n\(entries[0].token)\nB\n\(entries[1].token)\n\(entries[2].token)\n\(entries[3].token)"
        let report = try ManualMarkdownExporter().export(draft: draft, attachments: entries, to: root)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("A\n[照片：photo.jpg](photo.jpg)\nB"))
        XCTAssertTrue(md.contains("[照片：photo-2.jpg](photo-2.jpg)"))
        XCTAssertTrue(md.contains("[视频：movie.mp4](movie.mp4)"))
        XCTAssertFalse(md.contains("[[")); XCTAssertFalse(md.contains("alias.jpg"))
        XCTAssertEqual(report.imageCount, 2); XCTAssertEqual(report.videoCount, 1)
        let folder = report.markdownURL.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 4)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("photo.jpg")), try Data(contentsOf: photo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
    }

    func testMissingFilePreservesTextAndDoesNotMakeBrokenLink() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = ManualAttachment(id: 1, source: root.appendingPathComponent("missing.pdf"))
        let report = try ManualMarkdownExporter().export(draft: "A\n\(file.token)\nB", attachments: [file], to: root)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("A\n[附件未保存：missing.pdf]\nB"))
        XCTAssertFalse(md.contains("](missing.pdf)")); XCTAssertEqual(report.missingAttachmentCount, 1)
    }

    func testEmptyInputCreatesNothingAndUnicodeInsertionIsExact() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ManualMarkdownExporter().export(draft: " \n", attachments: [], to: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let edit = ManualDraft.inserting("新", into: "A🙂B", selection: NSRange(location: 1, length: 2))
        XCTAssertEqual(edit.text, "A新B"); XCTAssertEqual(edit.selection.location, 2)
    }

    @MainActor func testManualModelNeedsNoPermissionsAndDoesNotEraseSelectedText() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel()
        model.draftText = "A🙂B"; model.outputDirectory = root
        let photo = root.appendingPathComponent("photo.jpg")
        try Data("photo".utf8).write(to: photo)
        model.insertAttachments([photo], at: NSRange(location: 1, length: 2))
        XCTAssertTrue(model.draftText.hasPrefix("A🙂\n\n")); XCTAssertTrue(model.draftText.hasSuffix("B"))
        XCTAssertFalse(model.accessibilityGranted); XCTAssertFalse(model.screenCaptureGranted)
        model.start()
        for _ in 0..<200 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        guard case let .finished(report) = model.runState else { return XCTFail("Manual export did not finish: \(model.runState)") }
        XCTAssertEqual(report.imageCount, 1); XCTAssertEqual(report.pageCount, 0)
    }

    func testCancellationBeforeStartCreatesNothing() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ManualMarkdownExporter().export(draft: "A", attachments: [], to: root)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
