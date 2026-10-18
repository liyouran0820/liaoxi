import XCTest
import CoreGraphics
@testable import ChatArchive

final class MediaRegionTests: XCTestCase {
    func testExporterDeduplicatesCollectedAndImportedCopies() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let workspace = try ArchiveWorkspace(parent: parent)
        let imported = parent.appendingPathComponent("manual.jpg")
        let first = workspace.directory.appendingPathComponent("saved.jpg")
        let repeated = workspace.directory.appendingPathComponent("overlap.jpg")
        for url in [imported, first, repeated] { try Data("identical image".utf8).write(to: url) }
        let report = try MarkdownExporter().export(lines: [], attachments: [], fileNames: [], quoteKeys: [], pages: 1,
                                                 usedAccessibility: false, sourceFiles: [imported, first, repeated, repeated],
                                                 existingDirectory: workspace.directory, to: parent)
        XCTAssertEqual(report.imageCount, 1)
        XCTAssertEqual(report.missingAttachmentCount, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path)),
                       Set([workspace.markdownURL.lastPathComponent, "saved.jpg"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        let md = try String(contentsOf: workspace.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("[照片：saved.jpg]"))
        XCTAssertFalse(md.contains("overlap.jpg"))
    }

    @MainActor
    func testOverlappingPageDownloadKeepsOneVerifiedCopy() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let collector = AttachmentCollector(directory: parent)
        let first = parent.appendingPathComponent("photo-1.jpg")
        let duplicate = parent.appendingPathComponent("photo-2.jpg")
        try Data("same original bytes".utf8).write(to: first)
        try Data("same original bytes".utf8).write(to: duplicate)
        try collector.acceptSavedFile(first)
        try collector.acceptSavedFile(duplicate)
        XCTAssertEqual(collector.files, [first])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
    }

    func testRejectsSearchHistoryWindows() {
        XCTAssertFalse(ChatWindowSelector.isMergedRecordTitle("搜索聊天记录"))
        XCTAssertFalse(ChatWindowSelector.isMergedRecordTitle("查找聊天记录"))
        XCTAssertFalse(ChatWindowSelector.isMergedRecordTitle("Search chat history"))
        XCTAssertTrue(ChatWindowSelector.isMergedRecordTitle("张三和李四的聊天记录"))
        XCTAssertTrue(ChatWindowSelector.isMergedRecordTitle("聊天记录"))
    }

    func testDirectWorkspaceKeepsAttachmentsBesideSameNameMarkdown() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let workspace = try ArchiveWorkspace(parent: parent)
        let photo = workspace.directory.appendingPathComponent("实际照片.png")
        try Data("original bytes".utf8).write(to: photo)
        let report = try MarkdownExporter().export(lines: ["聊天正文"], attachments: [], fileNames: [], quoteKeys: [], pages: 1,
                                                 usedAccessibility: false, sourceFiles: [photo], existingDirectory: workspace.directory, to: parent)
        XCTAssertEqual(report.markdownURL, workspace.markdownURL)
        XCTAssertEqual(report.imageCount, 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: workspace.directory.path)),
                       Set([workspace.markdownURL.lastPathComponent, "实际照片.png"]))
        workspace.writeIncomplete("已停止")
        XCTAssertEqual(try Data(contentsOf: photo), Data("original bytes".utf8))
        XCTAssertTrue(try String(contentsOf: workspace.markdownURL, encoding: .utf8).contains("实际照片.png"))
    }

    func testMediaIsMaskedBeforeOCRWithoutMaskingMessageRows() throws {
        let width = 560, height = 720
        var pixels = [UInt8](repeating: 250, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        func paint(_ rect: CGRect, color: (UInt8, UInt8, UInt8)) {
            for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * width + x) * 4
                pixels[i] = color.0; pixels[i + 1] = color.1; pixels[i + 2] = color.2
            } }
        }
        // Top-left image coordinates: two thumbnail shapes and small avatar / text shapes.
        paint(CGRect(x: 72, y: 150, width: 185, height: 165), color: (25, 130, 180))
        paint(CGRect(x: 72, y: 370, width: 115, height: 250), color: (160, 60, 35))
        paint(CGRect(x: 25, y: 120, width: 35, height: 35), color: (10, 100, 120))
        paint(CGRect(x: 72, y: 335, width: 200, height: 8), color: (20, 20, 20))
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let detector = MediaRegionDetector()
        let regions = detector.regions(in: image)
        XCTAssertEqual(regions.count, 2)
        let masked = detector.masking(image, regions: regions)
        let output = try XCTUnwrap(masked.dataProvider?.data) as Data
        XCTAssertEqual(output[(200 * width + 120) * 4], 255)
        XCTAssertEqual(output[(450 * width + 120) * 4], 255)
        XCTAssertLessThan(output[(338 * width + 120) * 4], 100)
    }
}
