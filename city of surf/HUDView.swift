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
                HStack {
                    Text("\(gameState.score) m")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)
                Spacer()
            }

            if gameState.isGameOver {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 18) {
                    Text("WIPEOUT")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(gameState.score) m")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
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
                    Text("Finger halten & gleiten · hoch springen · runter ducken")
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
