// 이 파일은 V4 도트 캔버스를 창 안에 비율대로 맞추는 공통 좌표 변환을 제공한다.

import CoreGraphics

public enum OfficeCanvasGeometry {
    public static let designSize = CGSize(width: 1_536, height: 1_024)

    public static func fittedFrame(in container: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0 else {
            return .zero
        }

        let scale = min(
            container.width / designSize.width,
            container.height / designSize.height
        )
        let fittedSize = CGSize(
            width: designSize.width * scale,
            height: designSize.height * scale
        )
        return CGRect(
            x: (container.width - fittedSize.width) / 2,
            y: (container.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }
}

public enum OfficeWhiteboardGeometry {
    public static let usageOrigin = CGPoint(x: 210, y: 425)
    public static let usageSize = CGSize(width: 108, height: 69)
    public static let horizontalShear: CGFloat = -59.0 / 108.0
    public static let interactionRect = CGRect(
        x: 188,
        y: 338,
        width: 158,
        height: 170
    )

    public static func usagePoint(
        x: CGFloat,
        y: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: usageOrigin.x + x,
            y: usageOrigin.y + horizontalShear * x + y
        )
    }
}
