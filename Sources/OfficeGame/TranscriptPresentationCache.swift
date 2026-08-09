// 이 파일은 종료된 대화의 타임라인 해석 결과를 제한된 메모리 안에서 재사용한다.

import Foundation

enum TranscriptPresentationProvider: String {
    case codex
    case claude
}

private struct TranscriptPresentationRevision: Equatable {
    let activities: [LiveFeedActivity]
    let response: String
    let responseUpdatedAt: Date
    let isRunning: Bool
    let isCompleted: Bool
}

@MainActor
final class TranscriptPresentationCache {
    private final class Entry: NSObject {
        let revision: TranscriptPresentationRevision
        let presentation: Any

        init(
            revision: TranscriptPresentationRevision,
            presentation: Any
        ) {
            self.revision = revision
            self.presentation = presentation
        }
    }

    static let shared = TranscriptPresentationCache()

    private let storage = NSCache<NSString, Entry>()

    init(
        countLimit: Int = 64,
        totalCostLimit: Int = 8 * 1_024 * 1_024
    ) {
        storage.countLimit = countLimit
        storage.totalCostLimit = totalCostLimit
    }

    func presentation<Value>(
        provider: TranscriptPresentationProvider,
        turnID: String,
        activities: [LiveFeedActivity],
        response: String,
        responseUpdatedAt: Date,
        isRunning: Bool,
        isCompleted: Bool = false,
        make: () -> Value
    ) -> Value {
        let key = "\(provider.rawValue):\(turnID)" as NSString
        let revision = TranscriptPresentationRevision(
            activities: activities,
            response: response,
            responseUpdatedAt: responseUpdatedAt,
            isRunning: isRunning,
            isCompleted: isCompleted
        )

        if
            let entry = storage.object(forKey: key),
            entry.revision == revision,
            let presentation = entry.presentation as? Value
        {
            return presentation
        }

        let presentation = make()
        storage.setObject(
            Entry(revision: revision, presentation: presentation),
            forKey: key,
            cost: Self.cost(
                activities: activities,
                response: response
            )
        )
        return presentation
    }

    private static func cost(
        activities: [LiveFeedActivity],
        response: String
    ) -> Int {
        max(
            1,
            response.utf8.count
                + activities.reduce(0) { partialResult, activity in
                    partialResult
                        + activity.id.utf8.count
                        + activity.kind.utf8.count
                        + activity.text.utf8.count
                        + 64
                }
        )
    }
}
