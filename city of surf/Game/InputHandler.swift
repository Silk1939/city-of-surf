//
//  InputHandler.swift
//  city of surf
//

import UIKit

enum SwipeDirection {
    case up, down
}

final class InputHandler: NSObject, UIGestureRecognizerDelegate {
    var onSteer: ((Float) -> Void)?
    var onVerticalSwipe: ((SwipeDirection) -> Void)?
    var onTap: (() -> Void)?

    private weak var view: UIView?
    private var panStartSurferX: Float = 0
    private var getSurferX: (() -> Float)?
    /// Sensitive 1:1 feel.
    private let pixelsPerMeter: CGFloat = 16

    func attach(to view: UIView, surferX: @escaping () -> Float) {
        self.view = view
        self.getSurferX = surferX
        view.isMultipleTouchEnabled = false
        view.isUserInteractionEnabled = true

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

        case .changed:
            // Invert: finger moves left on glass -> character moves left on screen.
            // (UIKit +X is right; our chase-cam mapping needs the minus.)
            if abs(translation.x) >= abs(translation.y) * 0.55 || abs(translation.x) > 6 {
                let worldX = panStartSurferX - Float(translation.x / pixelsPerMeter)
                onSteer?(worldX)
            }

        case .ended, .cancelled:
            let absX = abs(translation.x)
            let absY = abs(translation.y)
            if absY > absX && absY > 36 {
                if velocity.y < -180 || translation.y < -36 {
                    onVerticalSwipe?(.up)
                } else if velocity.y > 180 || translation.y > 36 {
                    onVerticalSwipe?(.down)
                }
                return
            }
            if absX > 6 {
                let worldX = panStartSurferX - Float(translation.x / pixelsPerMeter)
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
