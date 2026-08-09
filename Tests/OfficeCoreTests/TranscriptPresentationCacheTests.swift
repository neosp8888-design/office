// 이 파일은 종료된 대화 타임라인 캐시의 재사용과 무효화 경계를 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

@MainActor
final class TranscriptPresentationCacheTests: XCTestCase {
    func testFinishedRevisionIsReused() {
        let cache = TranscriptPresentationCache()
        var buildCount = 0

        let first: String = cachedValue(
            cache: cache,
            turnID: "turn-1",
            make: {
                buildCount += 1
                return "first"
            }
        )
        let second: String = cachedValue(
            cache: cache,
            turnID: "turn-1",
            make: {
                buildCount += 1
                return "second"
            }
        )

        XCTAssertEqual(first, "first")
        XCTAssertEqual(second, "first")
        XCTAssertEqual(buildCount, 1)
    }

    func testSameTimestampWithDifferentResponseRebuilds() {
        let cache = TranscriptPresentationCache()
        var buildCount = 0
        let updatedAt = Date(timeIntervalSince1970: 1_000)

        _ = cachedValue(
            cache: cache,
            turnID: "turn-1",
            response: "alpha",
            responseUpdatedAt: updatedAt,
            make: {
                buildCount += 1
                return "alpha"
            }
        ) as String
        let changed: String = cachedValue(
            cache: cache,
            turnID: "turn-1",
            response: "bravo",
            responseUpdatedAt: updatedAt,
            make: {
                buildCount += 1
                return "bravo"
            }
        )

        XCTAssertEqual(changed, "bravo")
        XCTAssertEqual(buildCount, 2)
    }

    func testActivityTextStatusAndOrderChangesRebuild() throws {
        let cache = TranscriptPresentationCache()
        var buildCount = 0
        let first = try activity(
            id: "one",
            text: "first",
            status: "completed"
        )
        let statusChanged = try activity(
            id: "one",
            text: "first",
            status: "running"
        )
        let textChanged = try activity(
            id: "one",
            text: "changed",
            status: "running"
        )
        let second = try activity(
            id: "two",
            text: "second",
            status: "completed"
        )

        for activities in [
            [first, second],
            [statusChanged, second],
            [textChanged, second],
            [second, textChanged],
        ] {
            _ = cachedValue(
                cache: cache,
                turnID: "turn-1",
                activities: activities,
                make: {
                    buildCount += 1
                    return buildCount
                }
            ) as Int
        }

        XCTAssertEqual(buildCount, 4)
    }

    func testUnchangedRunningRevisionIsReusedAndTransitionsRebuild() {
        let cache = TranscriptPresentationCache()
        var buildCount = 0

        for isRunning in [false, true, true, false] {
            _ = cachedValue(
                cache: cache,
                turnID: "turn-1",
                isRunning: isRunning,
                make: {
                    buildCount += 1
                    return buildCount
                }
            ) as Int
        }

        XCTAssertEqual(buildCount, 3)
    }

    func testCompletionStateChangeRebuildsTerminalRevision() {
        let cache = TranscriptPresentationCache()
        var buildCount = 0

        for isCompleted in [false, false, true] {
            _ = cachedValue(
                cache: cache,
                turnID: "turn-1",
                isCompleted: isCompleted,
                make: {
                    buildCount += 1
                    return buildCount
                }
            ) as Int
        }

        XCTAssertEqual(buildCount, 2)
    }

    func testProvidersDoNotShareTurnEntry() {
        let cache = TranscriptPresentationCache()
        var buildCount = 0

        for provider in [
            TranscriptPresentationProvider.codex,
            TranscriptPresentationProvider.claude,
            TranscriptPresentationProvider.codex,
            TranscriptPresentationProvider.claude,
        ] {
            _ = cachedValue(
                cache: cache,
                provider: provider,
                turnID: "same-turn",
                make: {
                    buildCount += 1
                    return provider.rawValue
                }
            ) as String
        }

        XCTAssertEqual(buildCount, 2)
    }

    func testFiftyFinishedTurnsAreReusedOnSecondPass() {
        let cache = TranscriptPresentationCache()
        var buildCount = 0

        for _ in 0..<2 {
            for characterIndex in 0..<5 {
                for turnIndex in 0..<10 {
                    let turnID = "\(characterIndex)-\(turnIndex)"
                    _ = cachedValue(
                        cache: cache,
                        turnID: turnID,
                        response: turnID,
                        make: {
                            buildCount += 1
                            return turnID
                        }
                    ) as String
                }
            }
        }

        XCTAssertEqual(buildCount, 50)
    }

    private func cachedValue<Value>(
        cache: TranscriptPresentationCache,
        provider: TranscriptPresentationProvider = .codex,
        turnID: String,
        activities: [LiveFeedActivity] = [],
        response: String = "response",
        responseUpdatedAt: Date = Date(timeIntervalSince1970: 1_000),
        isRunning: Bool = false,
        isCompleted: Bool = false,
        make: () -> Value
    ) -> Value {
        cache.presentation(
            provider: provider,
            turnID: turnID,
            activities: activities,
            response: response,
            responseUpdatedAt: responseUpdatedAt,
            isRunning: isRunning,
            isCompleted: isCompleted,
            make: make
        )
    }

    private func activity(
        id: String,
        text: String,
        status: String
    ) throws -> LiveFeedActivity {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "kind": "tool",
            "text": text,
            "status": status,
            "occurredAt": "2026-08-06T00:00:00Z",
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LiveFeedActivity.self, from: data)
    }
}
