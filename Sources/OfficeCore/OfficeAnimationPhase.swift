// 이 파일은 V4 오피스 환경 효과의 시간 상태를 순수 계산해 렌더링과 테스트가 같은 값을 쓰게 한다.

import Foundation

public struct OfficeAnimationPhase: Equatable, Sendable {
    public let clockSecond: Int
    public let stageGlow: Double

    private let animationTime: TimeInterval
    private let reduceMotion: Bool

    public init(date: Date, reduceMotion: Bool) {
        let epochTime = date.timeIntervalSince1970
        let wholeSecond = Int(floor(epochTime))

        clockSecond = ((wholeSecond % 60) + 60) % 60
        stageGlow = reduceMotion
            ? 0.5
            : 0.5 + 0.5 * sin(epochTime * 2 * .pi / 4.8)
        animationTime = reduceMotion ? 0 : epochTime
        self.reduceMotion = reduceMotion
    }

    public func windowLightOpacity(at index: Int) -> Double {
        let periods = [16.0, 21.0, 27.0, 19.0, 32.0]
        let phaseOffsets = [0.2, 1.9, 3.4, 4.7, 5.6]
        let safeIndex = ((index % periods.count) + periods.count) % periods.count

        if reduceMotion {
            return 0.5 + Double(safeIndex) * 0.08
        }

        let wave = 0.5 + 0.5 * sin(
            animationTime * 2 * .pi / periods[safeIndex]
                + phaseOffsets[safeIndex]
        )
        return wave
    }

    public func monitorGlowOpacity(at index: Int) -> Double {
        let periods = [7.0, 9.5, 12.0, 8.5, 11.0]
        let phaseOffsets = [0.4, 2.1, 4.0, 5.2, 1.3]
        let safeIndex = ((index % periods.count) + periods.count) % periods.count

        if reduceMotion {
            return 0.5
        }

        return 0.5 + 0.5 * sin(
            animationTime * 2 * .pi / periods[safeIndex]
                + phaseOffsets[safeIndex]
        )
    }
}
