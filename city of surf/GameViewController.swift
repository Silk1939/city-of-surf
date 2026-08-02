//
//  GameViewController.swift
//  city of surf
//

import UIKit
import MetalKit
import SwiftUI
import Combine

final class GameViewController: UIViewController {

    private var renderer: Renderer!
    private var mtkView: MTKView!
    private let gameState = GameState()
    private let inputHandler = InputHandler()
    private var hudHost: UIHostingController<HUDView>?
    private var errorLabel: UILabel?
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let mtkView = view as? MTKView else {
            showError("View is not an MTKView")
            return
        }
        self.mtkView = mtkView

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            showError("Metal wird auf diesem Gerät nicht unterstützt.")
            return
        }

#if targetEnvironment(simulator)
        showError("Flood Surfer braucht Metal 4 auf einem echten iPhone.\nSimulator wird nicht unterstützt.")
        return
#else
        guard defaultDevice.supportsFamily(.metal4) else {
            showError("Metal 4 fehlt auf diesem Gerät.\nMindestens ein iPhone mit iOS 26+ und Metal-4-GPU.")
            return
        }

        mtkView.device = defaultDevice
        mtkView.backgroundColor = .black
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60

        guard let newRenderer = Renderer(metalKitView: mtkView, gameState: gameState) else {
            showError("Renderer konnte nicht initialisiert werden.")
            return
        }

        renderer = newRenderer
        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        mtkView.delegate = renderer

        setupHUD()
        setupInput()
#endif
    }

    private func setupHUD() {
        let host = UIHostingController(rootView: HUDView(gameState: gameState))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        hudHost = host
        host.view.isUserInteractionEnabled = false
        gameState.$isGameOver
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOver in
                self?.hudHost?.view.isUserInteractionEnabled = isOver
            }
            .store(in: &cancellables)
    }

    private func setupInput() {
        inputHandler.attach(to: mtkView) { [weak self] in
            self?.gameState.surfer.targetX ?? 0
        }
        inputHandler.onSteer = { [weak self] x in
            self?.gameState.steer(toWorldX: x)
        }
        inputHandler.onFlick = { [weak self] meters in
            self?.gameState.flick(meters: meters)
        }
        inputHandler.onVerticalSwipe = { [weak self] direction in
            self?.gameState.handleVertical(direction)
        }
        inputHandler.onTap = { [weak self] in
            guard let self else { return }
            if self.gameState.isGameOver {
                self.gameState.reset()
            }
        }
        view.isUserInteractionEnabled = true
    }

    private func showError(_ message: String) {
        view.backgroundColor = .black
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        errorLabel = label
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}
