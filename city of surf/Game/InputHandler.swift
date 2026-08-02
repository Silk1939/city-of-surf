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
    private let pixelsPerMeter: CGFloat = 42

    func attach(to view: UIView, surferX: @escaping () -> Float) {
        self.view = view
        self.getSurferX = surferX
        view.isMultipleTouchEnabled = false
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self

        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeUp.direction = .up
        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeDown.direction = .down
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))

        pan.require(toFail: swipeUp)
        pan.require(toFail: swipeDown)

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(swipeUp)
        view.addGestureRecognizer(swipeDown)
        view.addGestureRecognizer(tap)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        switch gesture.state {
        case .began:
            panStartSurferX = getSurferX?() ?? 0  // world X; swipe left -> character left
        case .changed, .ended:
            let dx = gesture.translation(in: view).x
            onSteer?(panStartSurferX - Float(dx / pixelsPerMeter))
        default:
            break
        }
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .up: onVerticalSwipe?(.up)
        case .down: onVerticalSwipe?(.down)
        default: break
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
