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

    /// 아파트 창문은 각자 다른 간격으로 임의 점등하고 전환만 은은하게 잇는다.
    public func windowLightOpacity(at index: Int) -> Double {
        guard !reduceMotion else {
            return Self.windowLightLevel(index: index, slot: 0)
        }

        let hold = Self.windowLightHold(index: index)
        let position = animationTime / hold
        let slot = position.rounded(.down)
        let elapsed = (position - slot) * hold
        let current = Self.windowLightLevel(index: index, slot: Int(slot))

        guard elapsed > hold - Self.windowLightFade else {
            return current
        }

        let next = Self.windowLightLevel(index: index, slot: Int(slot) + 1)
        let progress =
            (elapsed - (hold - Self.windowLightFade)) / Self.windowLightFade
        return current + (next - current) * Self.smoothStep(progress)
    }

    /// 옥상 헬기 경고등은 약한 잔광 위에서 짧게 한 번씩 밝아진다.
    public func rooftopBeaconOpacity(at index: Int) -> Double {
        let periods = [3.8, 4.6, 5.4]
        let phaseOffsets = [0.0, 1.7, 3.1]
        let safeIndex = ((index % periods.count) + periods.count) % periods.count

        guard !reduceMotion else {
            return 0.72
        }

        let flash = 0.45
        let elapsed = (animationTime + phaseOffsets[safeIndex])
            .truncatingRemainder(dividingBy: periods[safeIndex])

        guard elapsed < flash else {
            return Self.beaconAfterglow
        }
        return Self.beaconAfterglow
            + (1 - Self.beaconAfterglow) * sin(.pi * elapsed / flash)
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

    private static let windowLightFade = 2.4
    private static let beaconAfterglow = 0.14

    /// 창문 하나가 같은 밝기를 유지하는 12~26초 구간.
    private static func windowLightHold(index: Int) -> Double {
        12 + Double(hash(index, -1) % 15)
    }

    private static func windowLightLevel(index: Int, slot: Int) -> Double {
        let value = hash(index, slot)
        guard value % 100 >= 36 else {
            return 0.14
        }
        return 0.54 + Double(value / 100 % 32) / 100
    }

    private static func smoothStep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func hash(_ lhs: Int, _ rhs: Int) -> Int {
        var value = UInt64(truncatingIfNeeded: lhs &* 73_856_093)
        value ^= UInt64(truncatingIfNeeded: rhs &* 19_349_663)
        value ^= value >> 33
        value = value &* 0xFF51_AFD7_ED55_8CCD
        value ^= value >> 33
        return Int(value % 1_000_000)
    }
}
