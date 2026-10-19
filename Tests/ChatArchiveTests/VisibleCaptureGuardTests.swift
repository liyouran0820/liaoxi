import XCTest
import CoreGraphics
@testable import ChatArchive

final class VisibleCaptureGuardTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1470, height: 956)
    private let target = VisibleWindowInfo(id: 10, owner: 100, frame: CGRect(x: 455, y: 101, width: 560, height: 720))

    func testFailureKeepsItsSpecificReasonAndCancellationIsDistinct() {
        XCTAssertTrue(ExtractionPipeline.failureDescription(for: VisibleCaptureError.covered).contains("遮挡"))
        XCTAssertTrue(ExtractionPipeline.failureDescription(for: ExtractionError.noContent).contains("没有识别到聊天内容"))
        let cancellation = ExtractionPipeline.failureDescription(for: CancellationError())
        XCTAssertTrue(cancellation.contains("已停止提取"))
        XCTAssertFalse(cancellation.contains("提取失败"))
    }

    func testBlankPixelsDoNotPassAsReadableContent() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 320, bitsPerComponent: 8,
            bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 320))
        XCTAssertFalse(VisibleCaptureGuard.hasPixelVariation(try XCTUnwrap(context.makeImage())))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 80, y: 80, width: 40, height: 40))
        XCTAssertTrue(VisibleCaptureGuard.hasPixelVariation(try XCTUnwrap(context.makeImage())))
        context.clear(CGRect(x: 0, y: 0, width: 256, height: 320))
        XCTAssertFalse(VisibleCaptureGuard.hasPixelVariation(try XCTUnwrap(context.makeImage())))
    }

    func testRecordIdentityUsesNativeMetadataNotOCRNickname() {
        XCTAssertTrue(VisibleCaptureGuard.sameRecord(expectedTitle: "Alice01和Bob的聊天记录", currentTitle: "Alice01和Bob的聊天记录"))
        XCTAssertTrue(VisibleCaptureGuard.sameRecord(expectedTitle: " 聊天记录 ", currentTitle: "聊天记录"))
        XCTAssertFalse(VisibleCaptureGuard.sameRecord(expectedTitle: "Alice01和Bob的聊天记录", currentTitle: "Alice0l和Bob的聊天记录"))
        XCTAssertFalse(VisibleCaptureGuard.sameRecord(expectedTitle: "Alice和Bob的聊天记录", currentTitle: "Carol和Dave的聊天记录"))
        XCTAssertFalse(VisibleCaptureGuard.sameRecord(expectedTitle: nil, currentTitle: "聊天记录"))
        XCTAssertFalse(VisibleCaptureGuard.sameRecord(expectedTitle: "微信", currentTitle: "微信"))
    }

    func testRecordInFrontIsAllowedAndBackgroundWindowIgnored() {
        let background = VisibleWindowInfo(id: 20, owner: 200, frame: display)
        XCTAssertNoThrow(try VisibleCaptureGuard.validate(target: target, display: display, windows: [target, background]))
    }

    func testOverlappingWindowOrSameAppMenuBlocksCapture() {
        for pid: Int32 in [100, 200] {
            let cover = VisibleWindowInfo(id: 20, owner: pid, frame: CGRect(x: 500, y: 150, width: 200, height: 200))
            XCTAssertThrowsError(try VisibleCaptureGuard.validate(target: target, display: display, windows: [cover, target]))
        }
    }

    func testNonOverlappingAndTransparentWindowsAreAllowed() {
        let beside = VisibleWindowInfo(id: 20, owner: 200, frame: CGRect(x: 0, y: 100, width: 400, height: 400))
        let transparent = VisibleWindowInfo(id: 30, owner: 300, frame: display, alpha: 0)
        XCTAssertNoThrow(try VisibleCaptureGuard.validate(target: target, display: display, windows: [beside, transparent, target]))
    }

    func testMovedMissingOffscreenAndTransparentTargetsAreRejected() {
        var moved = target
        moved = VisibleWindowInfo(id: moved.id, owner: moved.owner, frame: moved.frame.offsetBy(dx: 20, dy: 0))
        XCTAssertThrowsError(try VisibleCaptureGuard.validate(target: target, display: display, windows: [moved]))
        XCTAssertThrowsError(try VisibleCaptureGuard.validate(target: target, display: display, windows: []))
        XCTAssertThrowsError(try VisibleCaptureGuard.validate(target: target, display: CGRect(x: 0, y: 0, width: 800, height: 600), windows: [target]))
        let transparent = VisibleWindowInfo(id: target.id, owner: target.owner, frame: target.frame, alpha: 0.5)
        XCTAssertThrowsError(try VisibleCaptureGuard.validate(target: target, display: display, windows: [transparent]))
    }

    func testNegativeCoordinatesOnARealSecondDisplayAreAllowed() {
        let second = CGRect(x: -1470, y: 0, width: 1470, height: 956)
        let window = VisibleWindowInfo(id: 10, owner: 100, frame: CGRect(x: -1000, y: 100, width: 560, height: 720))
        XCTAssertNoThrow(try VisibleCaptureGuard.validate(target: window, display: second, windows: [window]))
    }
}
