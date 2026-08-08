//
//  Camera.swift
//  city of surf
//
//  LOCKED with WaveField framing preset:
//    crestShift 3.2 → lip at z≈-3.2
//    eyeOffset.z -2.2 → eye AHEAD of lip (must stay > -crestShift)
//    look ahead down-canyon — never skim into the face normal (cyan wall).
//

import simd

struct ChaseCamera {
    /// Co-scaled with WaveField amp≈4.5 / crestShift≈3.2. Eye-Z must stay > -crestShift.
    ///
    /// Die Höhe ist der sekundäre Anteil von Befund A (Fall 1): mit 5.2 m stand das Auge
    /// 4.05 m über dem Surfer bei nur 2.2 m Abstand nach hinten, die Blickachse zeigte
    /// also 42.8° nach unten. Bei 34.04° halbem vertikalen FOV liegt der Horizont dann
    /// außerhalb des Bildes. Der Wert wird gesenkt, bis die Blickachse flacher als das
    /// halbe FOV steht. Eye-Z bleibt bei -2.2 (Kamera vor der Lippe, siehe WaveField).
    var eyeOffset = SIMD3<Float>(0, 2.4, -2.2)
    /// NUR die horizontale Blickrichtung — die Straße hinunter. Die y-Komponente wird
    /// bewusst nicht mehr benutzt: sie war der primäre Anteil von Befund A (Fall 4).
    /// Die vertikale Bildlage macht `screenAnchorY`, siehe `lookTarget(follow:)`.
    var lookAhead = SIMD3<Float>(0, 0, 10.0)
    /// Soll-Bildlage des Surfer-Ursprungs in NDC y: -1 unterer Bildrand, 0 Bildmitte.
    /// -0.5 ist das untere Bilddrittel. Sinnvoll: -0.85 … -0.15 (Zielband Schritt 3).
    var screenAnchorY: Float = -0.5
    var smoothEye = SIMD3<Float>(0, 10, -4)
    var fovDegrees: Float = 68
    var nearZ: Float = 0.12
    var farZ: Float = 320
    private var shakeOffset = SIMD3<Float>(repeating: 0)
    private var initialized = false
    private var impulse = SIMD3<Float>.zero
    private var rollBias: Float = 0
    private var speedFovBoost: Float = 0

    mutating func invalidate() {
        initialized = false
        impulse = .zero
        rollBias = 0
        speedFovBoost = 0
    }

    mutating func addImpulse(_ v: SIMD3<Float>) {
        let capped = SIMD3(
            max(-0.85, min(0.85, v.x)),
            max(-0.85, min(0.85, v.y)),
            max(-0.85, min(0.85, v.z))
        )
        impulse += capped
        impulse = SIMD3(
            max(-1.3, min(1.3, impulse.x)),
            max(-1.3, min(1.3, impulse.y)),
            max(-1.3, min(1.3, impulse.z))
        )
    }

    mutating func update(
        follow target: SIMD3<Float>,
        waveHeight: Float,
        eyeWaterHeight: Float,
        lean: Float,
        shake: Float,
        speed: Float = 18,
        deltaTime: Float
    ) {
        var desired = target + eyeOffset
        // Stay above local face water; clearance matches locked preset.
        let clearance: Float = 2.2
        desired.y = max(waveHeight + eyeOffset.y, eyeWaterHeight + clearance)
        desired.x += lean * 1.2
        desired.y += shake * 0.8
        desired += impulse
        impulse *= max(0, 1 - deltaTime * 9)

        if !initialized {
            smoothEye = desired
            initialized = true
        }

        let blend = min(1, deltaTime * 8)
        smoothEye += (desired - smoothEye) * blend
        let minEyeY = eyeWaterHeight + clearance
        if smoothEye.y < minEyeY {
            smoothEye.y = minEyeY
        }

        let targetRoll = lean * 0.04
        rollBias += (targetRoll - rollBias) * min(1, deltaTime * 5.5)
        let speedT = saturate((speed - 17) / 17)
        speedFovBoost += (speedT * 4.0 - speedFovBoost) * min(1, deltaTime * 2.6)
        fovDegrees = 68 + speedFovBoost

        if shake > 0.01 {
            let s = shake * shake * 0.45
            shakeOffset = SIMD3(
                Float.random(in: -0.12...0.12) * s,
                Float.random(in: -0.09...0.09) * s,
                Float.random(in: -0.07...0.07) * s
            )
        } else {
            shakeOffset *= 0.65
        }
    }

    private func saturate(_ v: Float) -> Float { max(0, min(1, v)) }

    /// Der Punkt, auf den die Kamera zielt — die einzige Quelle der Blickrichtung.
    ///
    /// Befund A war strukturell: `lookAhead` hing den Zielpunkt 10 m VOR dem Surfer auf
    /// eine feste Welthöhe. Wie weit der Surfer damit unter der Blickachse landet, hängt
    /// dann an Abstand, Augenhöhe und Wellenhöhe — bei 44.83° unter der Achse und 34.04°
    /// halbem FOV fällt er aus dem Bild. Ein konstanter Gegenoffset würde denselben
    /// Fehler nur bei einer Wellenhöhe kompensieren und bei Sprüngen wieder brechen.
    ///
    /// Deshalb wird die Richtung in zwei unabhängige Anteile zerlegt:
    ///  * `lookAhead.x/z` gibt die HORIZONTALE Richtung (Straße hinunter),
    ///  * der Nickwinkel folgt aus dem Surfer selbst. Die Achse liegt genau
    ///    `atan(-screenAnchorY * tan(fov/2))` über ihm.
    ///
    /// Für einen Punkt in der vertikalen Kameraebene gilt ndc.y = tan(θ_Surfer − Pitch) /
    /// tan(fov/2); mit dieser Wahl des Pitch ist ndc.y per Konstruktion `screenAnchorY`,
    /// unabhängig von Abstand, Sprunghöhe und Wellenhöhe.
    func lookTarget(follow target: SIMD3<Float>) -> SIMD3<Float> {
        let eye = smoothEye + shakeOffset
        let aim = target + shakeOffset * 0.2
        let toAim = aim - eye

        var heading = SIMD3<Float>(toAim.x + lookAhead.x, 0, toAim.z + lookAhead.z)
        let headingLength = simd_length(heading)
        heading = headingLength > 1e-4 ? heading / headingLength : SIMD3(0, 0, 1)

        // Winkel, unter dem der Surfer gerade steht (negativ = unter der Horizontalen).
        let along = max(simd_dot(toAim, heading), 0.001)
        let surferAngle = atan2f(toAim.y, along)
        // Winkel, um den die Achse darüber liegen muss, damit er auf screenAnchorY landet.
        let anchor = max(-0.95, min(0.95, screenAnchorY))
        let lift = atanf(-anchor * tanf(Math.radians(fovDegrees) * 0.5))
        let pitch = surferAngle + lift

        let distance = max(simd_length(toAim), 1)
        let forward = heading * cosf(pitch) + SIMD3<Float>(0, 1, 0) * sinf(pitch)
        return eye + forward * distance
    }

    func viewMatrix(follow target: SIMD3<Float>) -> matrix_float4x4 {
        let eye = smoothEye + shakeOffset
        let look = lookTarget(follow: target)
        var view = Math.lookAt(eye: eye, target: look, up: SIMD3(0, 1, 0))
        if abs(rollBias) > 0.0001 {
            view = Math.rotation(radians: rollBias, axis: SIMD3(0, 0, 1)) * view
        }
        return view
    }

    func projectionMatrix(aspect: Float) -> matrix_float4x4 {
        Math.perspective(fovyRadians: Math.radians(fovDegrees), aspectRatio: aspect, nearZ: nearZ, farZ: farZ)
    }
}

extension ChaseCamera {

    /// Einziger Ort, an dem die Kamera pro Frame nachgeführt wird.
    ///
    /// Renderer und Test-Harness rufen exakt diese Funktion. Sonst würde der
    /// Harness eine Kamera messen, die es im Spiel gar nicht gibt — dieselbe Falle
    /// wie ein Höhenfeld, das CPU und Shader getrennt berechnen.
    mutating func follow(
        surfer: SurferController,
        wave: WaveField,
        time: Float,
        scrollZ: Float,
        shake: Float,
        speed: Float,
        deltaTime: Float
    ) {
        let waveY = wave.height(
            x: surfer.x,
            z: surfer.position.z,
            time: time,
            scrollZ: scrollZ
        )
        // Sample water under the chase eye so we never bury the camera in the crest.
        let eyeZ = surfer.position.z + eyeOffset.z
        let eyeX = surfer.position.x + surfer.lean * 1.35
        let eyeWaterY = wave.height(x: eyeX, z: eyeZ, time: time, scrollZ: scrollZ)
        update(
            follow: surfer.position,
            waveHeight: waveY,
            eyeWaterHeight: eyeWaterY,
            lean: surfer.lean,
            shake: shake,
            speed: speed,
            deltaTime: deltaTime
        )
    }
}
