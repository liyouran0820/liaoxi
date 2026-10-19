import AppKit
import XCTest
@testable import ChatArchive

final class CaptureRecoveryTests: XCTestCase {
    func testDetachedDisplayCoordinatesAreNotSelected() {
        let main = CGRect(x: 0, y: 0, width: 1280, height: 832)
        let parked = CGRect(x: -2586, y: 101, width: 560, height: 720)
        XCTAssertFalse(ChatWindowSelector.isOnConnectedDisplay(parked, displays: [main]))
        XCTAssertTrue(ChatWindowSelector.isOnConnectedDisplay(CGRect(x: 455, y: 101, width: 560, height: 720), displays: [main]))
        XCTAssertTrue(ChatWindowSelector.isOnConnectedDisplay(parked, displays: [main, CGRect(x: -2732, y: 0, width: 2732, height: 1800)]))
    }

    @MainActor
    private func fixture(color: NSColor, drawMessages: Bool = false) throws -> CGImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 560, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        color.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 560, height: 720)).fill()
        if drawMessages {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]
            ("Alice" as NSString).draw(at: CGPoint(x: 72, y: 610), withAttributes: attributes)
            ("BEFORE 照片前的消息文字" as NSString).draw(at: CGPoint(x: 72, y: 565), withAttributes: attributes)
            NSColor.systemBlue.setFill()
            NSBezierPath(rect: CGRect(x: 72, y: 335, width: 180, height: 180)).fill()
            ("SECRET PHOTO" as NSString).draw(at: CGPoint(x: 80, y: 420), withAttributes: attributes)
            ("Bob" as NSString).draw(at: CGPoint(x: 72, y: 285), withAttributes: attributes)
            ("AFTER 照片后的消息文字" as NSString).draw(at: CGPoint(x: 72, y: 240), withAttributes: attributes)
        }
        return try XCTUnwrap(rep.cgImage)
    }

    @MainActor
    func testBlankAndTransparentFramesAreRejected() throws {
        for color in [NSColor.white, .black, .clear, .systemBlue] {
            XCTAssertFalse(CaptureQuality.hasVisibleContent(try fixture(color: color)))
        }
        XCTAssertTrue(CaptureQuality.hasVisibleContent(try fixture(color: .white, drawMessages: true)))
    }

    @MainActor
    func testActualVisionToMarkdownPreservesBothMessagesAroundPhoto() async throws {
        let image = try fixture(color: .white, drawMessages: true)
        let detector = MediaRegionDetector()
        let regions = detector.regions(in: image)
        XCTAssertEqual(regions.count, 1)
        let recognized = try await OCRService().recognize(detector.masking(image, regions: regions))
        let recognizedText = recognized.map(\.text).joined(separator: " ").uppercased()
        XCTAssertTrue(recognizedText.contains("BEFORE"))
        XCTAssertTrue(recognizedText.contains("AFTER"))
        XCTAssertFalse(recognizedText.contains("SECRET"))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let photo = parent.appendingPathComponent("photo.png")
        try Data("original attachment fixture".utf8).write(to: photo)
        let placement = PositionedAttachment(file: photo, bounds: try XCTUnwrap(regions.first))
        let lines = ContentProcessor().mergePages([AttachmentTimeline.inserting([placement], into: recognized)])
        let report = try MarkdownExporter().export(lines: lines, attachments: [], fileNames: [], quoteKeys: [],
            pages: 1, usedAccessibility: false, sourceFiles: [photo], attachmentReferences: [placement.marker: photo], to: parent)
        let md = try String(contentsOf: report.markdownURL, encoding: .utf8)
        let before = try XCTUnwrap(md.range(of: "BEFORE"))
        let link = try XCTUnwrap(md.range(of: "[照片：photo.png](photo.png)"))
        let after = try XCTUnwrap(md.range(of: "AFTER"))
        XCTAssertLessThan(before.lowerBound, link.lowerBound)
        XCTAssertLessThan(link.lowerBound, after.lowerBound)
        XCTAssertGreaterThan(report.textLineCount, 2)
    }

    func testFailureDocumentCarriesSpecificReasonWithoutDeletingAttachment() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ChatArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let workspace = try ArchiveWorkspace(parent: parent)
        let photo = workspace.directory.appendingPathComponent("retained.jpg")
        try Data("original".utf8).write(to: photo)
        workspace.writeIncomplete("提取失败：\(ExtractionError.blankCapture.localizedDescription)")
        let md = try String(contentsOf: workspace.markdownURL, encoding: .utf8)
        XCTAssertTrue(md.contains("空白画面"))
        XCTAssertTrue(md.contains("retained.jpg"))
        XCTAssertEqual(try Data(contentsOf: photo), Data("original".utf8))
    }
}
