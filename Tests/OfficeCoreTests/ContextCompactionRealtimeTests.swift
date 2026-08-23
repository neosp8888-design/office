import XCTest
@testable import OfficeGame

@MainActor
final class ContextCompactionRealtimeTests: XCTestCase {
    func testAutomaticCompactionStartAndCompletionUpdateVisibleState() throws {
        let director = AgentDirector(startBackgroundTasks: false)
        let started = try decode(
            #"{"type":"context.compaction.started","characterId":"left-woman","automatic":true}"#
        )

        XCTAssertTrue(
            director.applyRealtimeEvent(
                started,
                schedulesFeedRefresh: false
            )
        )
        XCTAssertTrue(director.compactingCharacters.contains(.leftWoman))
        XCTAssertTrue(director.bubbles[.leftWoman]?.hasPrefix("🗜️") == true)
        XCTAssertNil(director.contextCompactionNotice(for: .leftWoman))

        let completed = try decode(
            #"{"type":"context.compacted","characterId":"left-woman","automatic":true,"preTokens":652692,"postTokens":48120,"limitTokens":1000000}"#
        )
        XCTAssertTrue(
            director.applyRealtimeEvent(
                completed,
                schedulesFeedRefresh: false
            )
        )

        XCTAssertFalse(director.compactingCharacters.contains(.leftWoman))
        XCTAssertEqual(
            director.contextCompactionNotice(for: .leftWoman),
            .completed(
                automatic: true,
                preTokens: 652_692,
                postTokens: 48_120
            )
        )
        XCTAssertTrue(director.bubbles[.leftWoman]?.hasPrefix("✅") == true)
    }

    func testCompactionFailureClearsSpinnerAndKeepsFailureNotice() throws {
        let director = AgentDirector(startBackgroundTasks: false)
        _ = director.applyRealtimeEvent(
            RealtimeFeedEvent(
                type: "context.compaction.started",
                characterId: "boss",
                automatic: false
            ),
            schedulesFeedRefresh: false
        )

        let failed = try decode(
            #"{"type":"context.compaction.failed","characterId":"boss","automatic":false,"errorMessage":"압축기 실패"}"#
        )
        XCTAssertTrue(
            director.applyRealtimeEvent(
                failed,
                schedulesFeedRefresh: false
            )
        )

        XCTAssertFalse(director.compactingCharacters.contains(.boss))
        XCTAssertEqual(
            director.contextCompactionNotice(for: .boss),
            .failed(automatic: false, message: "압축기 실패")
        )
        XCTAssertTrue(director.bubbles[.boss]?.hasPrefix("⚠️") == true)
    }

    func testReadyEventRestoresCurrentCompactingCharacters() {
        let director = AgentDirector(startBackgroundTasks: false)
        _ = director.applyRealtimeEvent(
            RealtimeFeedEvent(
                type: "context.compaction.started",
                characterId: "boss"
            ),
            schedulesFeedRefresh: false
        )

        XCTAssertTrue(
            director.applyRealtimeEvent(
                RealtimeFeedEvent(
                    type: "ready",
                    compactingCharacterIds: ["left-woman"]
                ),
                schedulesFeedRefresh: false
            )
        )

        XCTAssertEqual(director.compactingCharacters, [.leftWoman])
        XCTAssertTrue(director.bubbles[.leftWoman]?.hasPrefix("🗜️") == true)
    }

    private func decode(_ source: String) throws -> RealtimeFeedEvent {
        try JSONDecoder().decode(
            RealtimeFeedEvent.self,
            from: Data(source.utf8)
        )
    }
}
