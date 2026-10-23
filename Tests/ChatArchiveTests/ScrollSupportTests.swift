import XCTest
@testable import ChatArchive

final class ScrollSupportTests: XCTestCase {
    func testPixelGestureIsChunkedWithoutLosingDirectionOrDistance() {
        for delta: Int32 in [-1200, -396, -1, 1, 396, 1200] {
            let chunks = RecordScrollPlan.chunks(for: delta, mode: .precise)
            XCTAssertEqual(chunks.reduce(0, +), delta)
            XCTAssertTrue(chunks.allSatisfy { abs($0) <= 40 && $0 != 0 && ($0 > 0) == (delta > 0) })
        }
        XCTAssertTrue(RecordScrollPlan.chunks(for: 0, mode: .precise).isEmpty)
    }

    func testWheelFallbackUsesSmallNonzeroLineSteps() {
        let chunks = RecordScrollPlan.chunks(for: -400, mode: .wheel)
        XCTAssertEqual(chunks.reduce(0, +), -20)
        XCTAssertTrue(chunks.allSatisfy { $0 < 0 && $0 >= -3 })
        XCTAssertEqual(RecordScrollPlan.chunks(for: 1, mode: .wheel), [1])
    }

    func testHitPointUsesCurrentFrameIncludingNegativeDisplayCoordinates() {
        let frame = CGRect(x: -1100, y: -300, width: 560, height: 720)
        let precise = RecordScrollPlan.location(in: frame, mode: .precise)
        let fallback = RecordScrollPlan.location(in: frame, mode: .wheel)
        XCTAssertTrue(frame.contains(precise)); XCTAssertTrue(frame.contains(fallback))
        XCTAssertEqual(precise.x, frame.minX + frame.width * 0.86, accuracy: 0.01)
        XCTAssertGreaterThan(precise.y, frame.minY + 120)
        XCTAssertNotEqual(precise.x, fallback.x)
        let moved = frame.offsetBy(dx: 1500, dy: 500)
        XCTAssertEqual(RecordScrollPlan.location(in: moved, mode: .precise).x - precise.x, 1500, accuracy: 0.01)
    }

    func testOnlyTheOriginalVisibleWindowMayReceiveEvents() {
        func match(_ id: CGWindowID, _ owner: pid_t, _ visible: Bool, _ frame: CGRect) -> Bool {
            RecordScrollPlan.matchesWindow(id: id, owner: owner, visible: visible, frame: frame, expectedID: 7, expectedOwner: 42)
        }
        let frame = CGRect(x: 0, y: 0, width: 560, height: 720)
        XCTAssertTrue(match(7, 42, true, frame))
        XCTAssertFalse(match(8, 42, true, frame)); XCTAssertFalse(match(7, 43, true, frame))
        XCTAssertFalse(match(7, 42, false, frame)); XCTAssertFalse(match(7, 42, true, .zero))
        XCTAssertFalse(match(7, 42, true, .infinite)); XCTAssertFalse(match(7, 42, true, .null))
    }

    func testRepeatedFrameDoesNotSilentlyDeclareFirstPageComplete() {
        XCTAssertEqual(ScrollAdvanceDecision.decide(original: "first", afterDown: ["first"], afterUp: nil, afterReturn: nil), .unconfirmed)
        XCTAssertEqual(ScrollAdvanceDecision.decide(original: "first", afterDown: ["first", "first"], afterUp: "first", afterReturn: "first"), .unconfirmed)
        XCTAssertEqual(ScrollAdvanceDecision.decide(original: "first", afterDown: ["first", "second"], afterUp: nil, afterReturn: nil), .nextPage)
    }

    func testBottomRequiresWorkingReverseProbeAndReturnToSameBoundary() {
        XCTAssertEqual(ScrollAdvanceDecision.decide(original: "bottom", afterDown: ["bottom", "bottom"], afterUp: "above", afterReturn: "bottom"), .confirmedBottom)
        XCTAssertEqual(ScrollAdvanceDecision.decide(original: "mid", afterDown: ["mid", "mid"], afterUp: "above", afterReturn: "next"), .nextPage)
        XCTAssertEqual(ScrollAdvanceDecision.decide(original: "bottom", afterDown: ["bottom"], afterUp: "above", afterReturn: "bottom"), .unconfirmed)
        XCTAssertEqual(ScrollAdvanceDecision.decide(original: "bottom", afterDown: ["bottom", "bottom"], afterUp: "above", afterReturn: nil), .unconfirmed)
    }
}
