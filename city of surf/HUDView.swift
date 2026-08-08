//
//  HUDView.swift
//  city of surf
//

import SwiftUI

struct HUDView: View {
    @ObservedObject var gameState: GameState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let sunset = Color(red: 1.0, green: 0.478, blue: 0.235)
    private let teal = Color(red: 0.18, green: 0.78, blue: 0.72)
    private let dusk = Color(red: 0.169, green: 0.227, blue: 0.404)

    var body: some View {
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(gameState.distanceScore) m")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(red: 1.0, green: 0.84, blue: 0.15))
                                .frame(width: 12, height: 12)
                            Text("\(gameState.coins)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 1.0, green: 0.9, blue: 0.35))
                                .scaleEffect(!reduceMotion && gameState.collectPulse > 0 ? 1.12 : 1.0)
                        }
                        Text("SCORE \(gameState.score)")
                            .font(.system(size: 12, weight: .heavy, design: .rounded))
                            .foregroundStyle(teal)
                        if gameState.stylePulse > 0.05 {
                            Text("STYLE")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(sunset)
                                .opacity(Double(gameState.stylePulse))
                                .scaleEffect(reduceMotion ? 1.0 : 1.0 + Double(gameState.stylePulse) * 0.08)
                        }
                    }
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    Spacer()
                    Text("CITY SURFER")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [sunset, .white, teal], startPoint: .leading, endPoint: .trailing)
                        )
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                Spacer()
            }
            .safeAreaPadding(.top)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: gameState.collectPulse)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: gameState.stylePulse)

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
                .padding(.bottom, 12)
                .safeAreaPadding(.bottom)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .allowsHitTesting(false)
            }

            if gameState.isGameOver {
                LinearGradient(
                    colors: [dusk.opacity(0.82), sunset.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                VStack(spacing: 14) {
                    Text("WIPEOUT")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [.white, sunset], startPoint: .top, endPoint: .bottom)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    HStack(spacing: 16) {
                        statBlock("\(gameState.distanceScore) m", "Distanz")
                        statBlock("\(gameState.coins)", "Coins", accent: Color(red: 1.0, green: 0.85, blue: 0.2))
                        statBlock("\(gameState.score)", "Score", accent: teal)
                    }
                    .foregroundStyle(.white)
                    Button {
                        gameState.reset()
                    } label: {
                        Text("NOCHMAL")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(dusk)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 12)
                            .background(sunset)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text("Gleiten · hoch springen · runter ducken")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 20)
                .safeAreaPadding()
            }
        }
        .allowsHitTesting(gameState.isGameOver)
    }

    private func statBlock(_ value: String, _ label: String, accent: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
