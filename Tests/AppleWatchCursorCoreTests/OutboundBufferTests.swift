import XCTest
@testable import AppleWatchCursorCore

final class OutboundBufferTests: XCTestCase {
    func testDelayedKeepaliveReplyDoesNotFreezeWristUpdates() {
        var queue = OutboundBuffer()
        XCTAssertTrue(queue.enqueue(.init(kind: .heartbeat)))
        XCTAssertEqual(queue.next(canSendMovement: true)?.kind, .heartbeat)
        XCTAssertTrue(queue.enqueue(.init(kind: .move, x: 0.2, y: 0.3)))
        XCTAssertEqual(queue.next(canSendMovement: true), .init(kind: .move, x: 0.2, y: 0.3))
        XCTAssertEqual(queue.pendingReliable, .heartbeat)
        XCTAssertTrue(queue.enqueue(.init(kind: .move, x: 0.4, y: 0.5)))
        XCTAssertEqual(queue.next(canSendMovement: true)?.x, 0.4)
    }
    func testClicksRetainReliableOrderingAndMovementWaitsForClickReply() {
        var queue = OutboundBuffer()
        _ = queue.enqueue(.init(kind: .heartbeat)); _ = queue.next(canSendMovement: true)
        _ = queue.enqueue(.init(kind: .click)); _ = queue.enqueue(.init(kind: .move, x: 0.5))
        XCTAssertEqual(queue.next(canSendMovement: true)?.kind, .move)
        queue.acknowledge()
        XCTAssertEqual(queue.next(canSendMovement: true)?.kind, .click)
        _ = queue.enqueue(.init(kind: .move, x: 0.8))
        XCTAssertNil(queue.next(canSendMovement: true))
        queue.acknowledge()
        XCTAssertEqual(queue.next(canSendMovement: true)?.x, 0.8)
    }
    func testBackpressureCoalescesToLatestMovementAndPauseDiscardsIt() {
        var queue = OutboundBuffer()
        _ = queue.enqueue(.init(kind: .move, x: 0.1)); _ = queue.enqueue(.init(kind: .move, x: 0.9))
        XCTAssertNil(queue.next(canSendMovement: false))
        XCTAssertEqual(queue.next(canSendMovement: true)?.x, 0.9)
        _ = queue.enqueue(.init(kind: .move, x: 0.7)); _ = queue.enqueue(.init(kind: .pause))
        XCTAssertEqual(queue.next(canSendMovement: true)?.kind, .pause)
        queue.acknowledge(); XCTAssertNil(queue.next(canSendMovement: true))
    }
}
