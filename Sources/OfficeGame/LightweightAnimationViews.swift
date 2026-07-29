// 이 파일은 업무 상태의 반복 모션을 Core Animation으로 그려 SwiftUI 레이아웃 갱신을 막는다.

import AppKit
import QuartzCore
import SwiftUI

struct CoreAnimationDotsView: NSViewRepresentable {
    let dotSize: CGFloat
    let spacing: CGFloat
    let travel: CGFloat
    let color: NSColor
    let isAnimated: Bool

    func makeNSView(context: Context) -> CoreAnimationDotsNSView {
        let view = CoreAnimationDotsNSView()
        view.configure(
            dotSize: dotSize,
            spacing: spacing,
            travel: travel,
            color: color,
            isAnimated: isAnimated
        )
        return view
    }

    func updateNSView(
        _ nsView: CoreAnimationDotsNSView,
        context: Context
    ) {
        nsView.configure(
            dotSize: dotSize,
            spacing: spacing,
            travel: travel,
            color: color,
            isAnimated: isAnimated
        )
    }
}

struct CoreAnimationRunningIndicator: NSViewRepresentable {
    let isAnimated: Bool

    func makeNSView(
        context: Context
    ) -> CoreAnimationRunningIndicatorNSView {
        let view = CoreAnimationRunningIndicatorNSView()
        view.setAnimated(isAnimated)
        return view
    }

    func updateNSView(
        _ nsView: CoreAnimationRunningIndicatorNSView,
        context: Context
    ) {
        nsView.setAnimated(isAnimated)
    }
}

final class CoreAnimationDotsNSView: NSView {
    private let dotLayers = (0..<3).map { _ in CAShapeLayer() }
    private var dotSize = CGFloat(4)
    private var spacing = CGFloat(2.5)
    private var travel = CGFloat(2.5)
    private var dotColor = NSColor(
        calibratedRed: 0.13,
        green: 0.55,
        blue: 0.52,
        alpha: 1
    )
    private var isAnimated = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for dotLayer in dotLayers {
            layer?.addSublayer(dotLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let totalWidth =
            dotSize * CGFloat(dotLayers.count)
            + spacing * CGFloat(dotLayers.count - 1)
        let startX = (bounds.width - totalWidth) / 2
        let y = (bounds.height - dotSize) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dotLayer) in dotLayers.enumerated() {
            dotLayer.frame = CGRect(
                x: startX + CGFloat(index) * (dotSize + spacing),
                y: y,
                width: dotSize,
                height: dotSize
            )
            dotLayer.path = CGPath(
                ellipseIn: CGRect(
                    origin: .zero,
                    size: CGSize(width: dotSize, height: dotSize)
                ),
                transform: nil
            )
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    func configure(
        dotSize: CGFloat,
        spacing: CGFloat,
        travel: CGFloat,
        color: NSColor,
        isAnimated: Bool
    ) {
        let geometryChanged =
            self.dotSize != dotSize
                || self.spacing != spacing
                || self.travel != travel
        let animationChanged = self.isAnimated != isAnimated
        self.dotSize = dotSize
        self.spacing = spacing
        self.travel = travel
        self.dotColor = color
        self.isAnimated = isAnimated

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dotLayer in dotLayers {
            dotLayer.fillColor = color.cgColor
        }
        CATransaction.commit()

        if geometryChanged {
            needsLayout = true
        }
        if geometryChanged || animationChanged {
            updateAnimations()
        }
    }

    private func updateAnimations() {
        for dotLayer in dotLayers {
            dotLayer.removeAnimation(forKey: "officestra.dots")
            dotLayer.opacity = 1
            dotLayer.transform = CATransform3DIdentity
        }
        guard isAnimated, window != nil else {
            return
        }

        let startTime = CACurrentMediaTime()
        for (index, dotLayer) in dotLayers.enumerated() {
            let bounce = CAKeyframeAnimation(
                keyPath: "transform.translation.y"
            )
            bounce.values = [0, travel, 0, 0]
            bounce.keyTimes = [0, 0.20, 0.42, 1]

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.42, 1, 0.42, 0.42]
            opacity.keyTimes = bounce.keyTimes

            let group = CAAnimationGroup()
            group.animations = [bounce, opacity]
            group.duration = 0.84
            group.beginTime = startTime + Double(index) * 0.16
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            dotLayer.add(group, forKey: "officestra.dots")
        }
    }
}

final class CoreAnimationRunningIndicatorNSView: NSView {
    private let ringLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private let runningColor = NSColor(
        calibratedRed: 0.18,
        green: 0.73,
        blue: 0.42,
        alpha: 1
    )
    private var isAnimated = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        update(
            ringLayer,
            size: 18,
            center: center
        )
        update(
            dotLayer,
            size: 12,
            center: center
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    func setAnimated(_ isAnimated: Bool) {
        guard self.isAnimated != isAnimated else {
            return
        }
        self.isAnimated = isAnimated
        updateAnimations()
    }

    private func configureLayers() {
        ringLayer.fillColor = NSColor.clear.cgColor
        ringLayer.strokeColor = runningColor.withAlphaComponent(0.58).cgColor
        ringLayer.lineWidth = 1.6
        dotLayer.fillColor = runningColor.cgColor
        dotLayer.shadowColor = runningColor.withAlphaComponent(0.34).cgColor
        dotLayer.shadowRadius = 4
        dotLayer.shadowOffset = CGSize(width: 0, height: -2)
        dotLayer.shadowOpacity = 1
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(dotLayer)
    }

    private func update(
        _ shapeLayer: CAShapeLayer,
        size: CGFloat,
        center: CGPoint
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: size, height: size)
        )
        shapeLayer.position = center
        shapeLayer.path = CGPath(
            ellipseIn: shapeLayer.bounds,
            transform: nil
        )
        CATransaction.commit()
    }

    private func updateAnimations() {
        ringLayer.removeAllAnimations()
        dotLayer.removeAllAnimations()
        ringLayer.opacity = 1
        dotLayer.opacity = 1
        ringLayer.transform = CATransform3DIdentity
        dotLayer.transform = CATransform3DIdentity
        guard isAnimated, window != nil else {
            return
        }

        addPulse(
            to: ringLayer,
            fromScale: 0.76,
            toScale: 1.26,
            fromOpacity: 0.96,
            toOpacity: 0.10
        )
        addPulse(
            to: dotLayer,
            fromScale: 0.84,
            toScale: 1,
            fromOpacity: 1,
            toOpacity: 0.72
        )
    }

    private func addPulse(
        to shapeLayer: CAShapeLayer,
        fromScale: CGFloat,
        toScale: CGFloat,
        fromOpacity: Float,
        toOpacity: Float
    ) {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = fromScale
        scale.toValue = toScale

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = toOpacity

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 0.62
        group.autoreverses = true
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.timingFunction = CAMediaTimingFunction(
            name: .easeInEaseOut
        )
        shapeLayer.add(group, forKey: "officestra.pulse")
    }
}
