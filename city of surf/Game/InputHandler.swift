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
    /// Fire jump/duck once mid-gesture when threshold is crossed (not only on finger-up).
    private var didFireVertical = false

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
            didFireVertical = false

        case .changed:
            tryFireVertical(translation: translation, velocity: velocity)
            // Invert: finger left → character left.
            if abs(translation.x) >= abs(translation.y) * 0.55 || abs(translation.x) > 6 {
                let worldX = panStartSurferX - Float(translation.x / pixelsPerMeter)
                onSteer?(worldX)
            }

        case .ended, .cancelled:
            if !didFireVertical {
                tryFireVertical(translation: translation, velocity: velocity)
            }
            if !didFireVertical, abs(translation.x) > 6 {
                let worldX = panStartSurferX - Float(translation.x / pixelsPerMeter)
                onSteer?(worldX)
            }

        default:
            break
        }
    }

    private func tryFireVertical(translation: CGPoint, velocity: CGPoint) {
        guard !didFireVertical else { return }
        let absX = abs(translation.x)
        let absY = abs(translation.y)
        // Allow slightly diagonal flicks; velocity can win when travel is short.
        let verticalDominant = absY > absX * 0.75 || abs(velocity.y) > abs(velocity.x) * 1.2
        guard verticalDominant else { return }

        if velocity.y < -220 || translation.y < -28 {
            didFireVertical = true
            onVerticalSwipe?(.up)
        } else if velocity.y > 220 || translation.y > 28 {
            didFireVertical = true
            onVerticalSwipe?(.down)
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
