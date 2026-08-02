//
//  HUDView.swift
//  city of surf
//

import SwiftUI

struct HUDView: View {
    @ObservedObject var gameState: GameState

    var body: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(gameState.distanceScore) m")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: 1.0, green: 0.84, blue: 0.15))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                            Text("\(gameState.coins)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 1.0, green: 0.9, blue: 0.35))
                                .scaleEffect(gameState.collectPulse > 0 ? 1.15 : 1.0)
                        }
                    }
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    Spacer()
                    Text("CITY SURFER")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color(red: 0.55, green: 0.95, blue: 0.2)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                Spacer()
            }
            .animation(.easeOut(duration: 0.15), value: gameState.collectPulse)

            if gameState.showDebugHUD {
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text("SMOKE platform=\(gameState.debugPlatformNote)")
                    Text("device=\(gameState.debugMetalDeviceOK ? "OK" : "FAIL")  metal4=\(gameState.debugMetal4OK ? "OK" : "FAIL")")
                    Text("renderer=\(gameState.debugRendererReady ? "OK" : "FAIL")  ktx=\(gameState.debugKTXLoaded ? "OK" : "FAIL")")
                    Text("iblPeak=\(String(format: "%.2f", gameState.debugIBLPeak))  shadow=\(gameState.debugShadowActive ? "OK" : "FAIL")")
                    Text("frame1=\(gameState.debugFirstFrameOK ? "OK" : "…")  FPS=\(gameState.debugFPS)")
                    Text(String(format: "texMem≈%.0fMB%@", gameState.debugTextureMemoryMB, gameState.debugTextureMemoryWarn ? " WARN" : ""))
                    if !gameState.debugLastError.isEmpty {
                        Text("ERR: \(gameState.debugLastError)")
                            .foregroundStyle(Color.red.opacity(0.95))
                            .lineLimit(4)
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                .padding(.leading, 12)
                .padding(.trailing, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }

            if gameState.isGameOver {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("WIPEOUT")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    HStack(spacing: 18) {
                        VStack {
                            Text("\(gameState.distanceScore) m")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("Distanz")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        VStack {
                            Text("\(gameState.coins)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.2))
                            Text("Coins")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        VStack {
                            Text("\(gameState.score)")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.55, green: 0.95, blue: 0.25))
                            Text("Score")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .foregroundStyle(.white)
                    Button {
                        gameState.reset()
                    } label: {
                        Text("NOCHMAL")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.95, green: 0.75, blue: 0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text("Finger gleiten · hoch springen · runter ducken (Ampeln!)")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
        }
        .allowsHitTesting(gameState.isGameOver)
    }
}
