//
//  InputHandler.swift
//  city of surf
//

import UIKit

enum SwipeDirection {
    case up, down
}

final class InputHandler: NSObject, UIGestureRecognizerDelegate {
    /// Absolute world-X while dragging.
    var onSteer: ((Float) -> Void)?
    /// Extra flick impulse in world meters (signed).
    var onFlick: ((Float) -> Void)?
    var onVerticalSwipe: ((SwipeDirection) -> Void)?
    var onTap: (() -> Void)?

    private weak var view: UIView?
    private var panStartSurferX: Float = 0
    private var getSurferX: (() -> Float)?
    /// Lower = more sensitive. ~18px ≈ 1m.
    private let pixelsPerMeter: CGFloat = 18
    private var didSteerHorizontally = false

    func attach(to view: UIView, surferX: @escaping () -> Float) {
        self.view = view
        self.getSurferX = surferX
        view.isMultipleTouchEnabled = false
        view.isUserInteractionEnabled = true

        // One pan handles steer + jump/duck (no require-to-fail delay).
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: pan)

        view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            panStartSurferX = getSurferX?() ?? 0
            didSteerHorizontally = false

        case .changed:
            // Finger left (dx < 0) -> world X decreases -> moves left on screen.
            if abs(translation.x) > abs(translation.y) * 0.6 || abs(translation.x) > 8 {
                didSteerHorizontally = true
                let worldX = panStartSurferX + Float(translation.x / pixelsPerMeter)
                onSteer?(worldX)
            }

        case .ended, .cancelled:
            let absX = abs(translation.x)
            let absY = abs(translation.y)

            // Vertical flick = jump / duck
            if absY > absX && absY > 40 {
                if velocity.y < -200 || translation.y < -40 {
                    onVerticalSwipe?(.up)
                } else if velocity.y > 200 || translation.y > 40 {
                    onVerticalSwipe?(.down)
                }
                return
            }

            // Horizontal flick boost for snappy lane hops
            if abs(velocity.x) > 600 {
                let impulse = Float(velocity.x / 900) // ~±1–3 m
                onFlick?(max(-3.5, min(3.5, impulse)))
            } else if didSteerHorizontally {
                let worldX = panStartSurferX + Float(translation.x / pixelsPerMeter)
                onSteer?(worldX)
            }

        default:
            break
        }
    }

    @objc private func handleTap() {
        onTap?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
