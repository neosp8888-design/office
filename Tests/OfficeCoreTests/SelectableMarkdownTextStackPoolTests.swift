// 선택 영역 전환 때 NSTextView 스택을 잠깐 맡아 두는 풀의 규칙을 검증한다.

import AppKit
import XCTest
@testable import OfficeGame

@MainActor
final class SelectableMarkdownTextStackPoolTests: XCTestCase {
    func testStoredStackIsTakenOnceByKey() {
        let pool = SelectableMarkdownTextStackPool()
        let stack = NSTextView()
        pool.store(stack, key: "a")

        XCTAssertNil(pool.take(key: "b"))
        XCTAssertTrue(pool.take(key: "a") === stack)
        XCTAssertNil(pool.take(key: "a"), "한 번 이어받은 스택은 다시 나오면 안 된다.")
    }

    // 곧바로 이어받지 않은 스택은 전환이 아니므로 버린다.
    func testStaleStackExpires() {
        let pool = SelectableMarkdownTextStackPool()
        let storedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        pool.store(NSTextView(), key: "a", now: storedAt)

        XCTAssertNil(
            pool.take(
                key: "a",
                now: storedAt.addingTimeInterval(
                    SelectableMarkdownTextStackPool.lifetime + 0.1
                )
            )
        )
        XCTAssertEqual(pool.count, 0)
    }

    func testCapacityDropsOldestEntries() {
        let pool = SelectableMarkdownTextStackPool()
        let now = Date()
        for index in 0...SelectableMarkdownTextStackPool.capacity {
            pool.store(NSTextView(), key: "k\(index)", now: now)
        }

        XCTAssertEqual(pool.count, SelectableMarkdownTextStackPool.capacity)
        XCTAssertNil(pool.take(key: "k0", now: now))
        XCTAssertNotNil(
            pool.take(
                key: "k\(SelectableMarkdownTextStackPool.capacity)",
                now: now
            )
        )
    }

    func testSameKeyKeepsLatestStack() {
        let pool = SelectableMarkdownTextStackPool()
        let first = NSTextView()
        let second = NSTextView()
        pool.store(first, key: "a")
        pool.store(second, key: "a")

        XCTAssertTrue(pool.take(key: "a") === second)
        XCTAssertEqual(pool.count, 0)
    }
}
