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

        // HUD early so start-check failures are visible in debug overlay.
        setupHUD()

        guard let mtkView = view as? MTKView else {
            failStart("MTKView fehlt — Root-View ist kein MTKView (Storyboard prüfen).")
            return
        }
        self.mtkView = mtkView

        // --- Device start checks ---
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            failStart("MTLCreateSystemDefaultDevice() = nil — Metal nicht verfügbar.")
            return
        }
        gameState.debugMetalDeviceOK = true
        logSmoke("CHECK OK: MTLCreateSystemDefaultDevice()")

#if targetEnvironment(simulator)
        gameState.debugPlatformNote = "simulator"
        failStart(
            "Simulator-Build — kein gültiger Metal-4-Test. " +
            "Flood Surfer braucht ein echtes iPhone (iOS 26.5+, Metal 4 / MTLGPUFamily.metal4)."
        )
        return
#else
        gameState.debugPlatformNote = "iphoneos"
        guard defaultDevice.supportsFamily(.metal4) else {
            failStart(
                "Metal 4 fehlt: supportsFamily(.metal4)=false. " +
                "Gerät: \(defaultDevice.name). Braucht iPhone mit iOS 26.5+ und Metal-4-GPU."
            )
            return
        }
        gameState.debugMetal4OK = true
        logSmoke("CHECK OK: Metal 4 (MTLGPUFamily.metal4) auf \(defaultDevice.name)")

        mtkView.device = defaultDevice
        mtkView.backgroundColor = .black
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        let screenScale = view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
        mtkView.contentScaleFactor = min(screenScale, 2.0)

        guard let newRenderer = Renderer(metalKitView: mtkView, gameState: gameState) else {
            let detail = Renderer.lastInitError
                ?? "Renderer.init returned nil ohne lastInitError"
            failStart(detail)
            return
        }

        renderer = newRenderer
        // Renderer.init sets: debugRendererReady, KTX, IBL peak, shadow, texture memory
        logSmoke("CHECK OK: Renderer initialisiert")
        if gameState.debugKTXLoaded {
            logSmoke("CHECK OK: KTX/PBR geladen, IBL peak=\(gameState.debugIBLPeak)")
        }
        if gameState.debugShadowActive {
            logSmoke("CHECK OK: Shadow Map erstellt")
        }
        logSmoke(String(format: "CHECK: Texture memory ≈ %.1f MB%@",
                        gameState.debugTextureMemoryMB,
                        gameState.debugTextureMemoryWarn ? " — WARN over budget" : ""))

        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        mtkView.delegate = renderer
        setupInput()
        logSmoke("Device start checks passed — warte auf ersten Frame…")
#endif
    }

    private func failStart(_ message: String) {
        gameState.debugLastError = message
        gameState.showDebugHUD = true
        logSmoke("CHECK FAIL: \(message)")
        showError(message)
    }

    private func logSmoke(_ message: String) {
        print("[FloodSurfer Smoke] \(message)")
    }

    private func setupHUD() {
        guard hudHost == nil else { return }
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
        errorLabel?.removeFromSuperview()
        view.backgroundColor = .black
        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        errorLabel = label
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let mtkView else { return }
        let screenScale = view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
        let capped = min(screenScale, 2.0)
        if abs(mtkView.contentScaleFactor - capped) > 0.01 {
            mtkView.contentScaleFactor = capped
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}
