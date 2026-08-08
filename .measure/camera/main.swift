// Host-Messung zu Befund A nach dem Umbau der Blickrichtung.
// Kompiliert die echten Spielquellen für macOS: Kamera, Höhenfeld, Surfer, Projektion.
// Kein Metal, keine Meshes. Der verbindliche Beleg bleibt das Test-Target.

import Foundation
import simd

@MainActor
func simulate(
    frames: Int,
    aspect: Float = 1170.0 / 2532.0,
    configureCamera: ((inout ChaseCamera) -> Void)? = nil
) -> (ndc: SIMD3<Float>, eye: SIMD3<Float>, pitch: Float, halfFov: Float,
      surfer: SIMD3<Float>, water: Float, angleBelow: Float, inFrustum: Bool) {
    let state = GameState()
    state.reset()
    var camera = ChaseCamera()
    configureCamera?(&camera)
    let dt: Float = 1.0 / 60.0
    for _ in 0..<frames {
        state.update(deltaTime: dt)
        camera.follow(
            surfer: state.surfer, wave: state.wave, time: state.time,
            scrollZ: state.scrollZ, shake: 0, speed: state.speed, deltaTime: dt
        )
    }
    let viewM = camera.viewMatrix(follow: state.surfer.position)
    let projM = camera.projectionMatrix(aspect: aspect)
    let vp = projM * viewM
    let eye = camera.smoothEye
    let target = camera.lookTarget(follow: state.surfer.position)
    let forward = simd_normalize(target - eye)
    let p = DiagnosticsMath.project(state.surfer.position, viewProjection: vp)
    let water = state.wave.height(
        x: state.surfer.x, z: state.surfer.position.z, time: state.time, scrollZ: state.scrollZ
    )
    return (
        p.ndc, eye, DiagnosticsMath.pitchDegrees(forward: forward), camera.fovDegrees * 0.5,
        state.surfer.position, water,
        DiagnosticsMath.angleBelowViewAxis(eye: eye, target: target, point: state.surfer.position),
        DiagnosticsMath.inFrustum(ndc: p.ndc)
    )
}

@MainActor
func main() {
    print("========== BEFUND A NACH DEM UMBAU ==========")
    for n in [1, 30, 120, 300, 600] {
        let r = simulate(frames: n)
        print(String(format:
            "Frame %4d  NDC y = %+.4f  sichtbar=%@  Auge-Y=%.3f  Surfer-Y=%.3f  ueber Wasser=%+.3f  Pitch=%+.2f  halbFOV=%.2f  Winkel unter Achse=%+.2f",
            n, r.ndc.y, r.inFrustum ? "ja  " : "nein", r.eye.y, r.surfer.y,
            r.surfer.y - r.water, r.pitch, r.halfFov, r.angleBelow))
    }

    print("")
    print("--- Robustheit: Anker haelt unabhaengig von Augenhoehe und Abstand ---")
    for h in [Float(1.2), 2.4, 3.6, 5.2, 8.0] {
        let r = simulate(frames: 120) { $0.eyeOffset = SIMD3($0.eyeOffset.x, h, $0.eyeOffset.z) }
        print(String(format: "eyeOffset.y=%4.1f  NDC y = %+.4f  Auge-Y=%.3f  Pitch=%+.2f  Horizont im Bild=%@",
                     h, r.ndc.y, r.eye.y, r.pitch,
                     abs(r.pitch) < r.halfFov ? "ja" : "nein"))
    }

    print("")
    print("--- Robustheit: Anker haelt bei Sprung (Surfer weit ueber Wasser) ---")
    // Sprung erzwingen: der Zustand wird ueber viele Frames simuliert und zwischendurch
    // gemessen; die Hoehe schwankt durch Welle und Sprungmechanik ohnehin.
    let state = GameState()
    state.reset()
    var camera = ChaseCamera()
    let dt: Float = 1.0 / 60.0
    var worstAbove = -Float.greatestFiniteMagnitude
    var worstNdc: Float = 0
    var minNdc = Float.greatestFiniteMagnitude
    var maxNdc = -Float.greatestFiniteMagnitude
    for i in 0..<900 {
        if i % 90 == 0 { state.handleVertical(.up) }
        state.update(deltaTime: dt)
        camera.follow(
            surfer: state.surfer, wave: state.wave, time: state.time,
            scrollZ: state.scrollZ, shake: 0, speed: state.speed, deltaTime: dt
        )
        let vp = camera.projectionMatrix(aspect: 1170.0 / 2532.0)
            * camera.viewMatrix(follow: state.surfer.position)
        let ndcY = DiagnosticsMath.project(state.surfer.position, viewProjection: vp).ndc.y
        let water = state.wave.height(
            x: state.surfer.x, z: state.surfer.position.z, time: state.time, scrollZ: state.scrollZ
        )
        let above = state.surfer.position.y - water
        if above > worstAbove { worstAbove = above; worstNdc = ndcY }
        if i > 10 {
            minNdc = min(minNdc, ndcY)
            maxNdc = max(maxNdc, ndcY)
        }
    }
    print(String(format: "900 Frames mit Spruengen: NDC y min=%+.4f max=%+.4f",
                 minNdc, maxNdc))
    print(String(format: "hoechster Punkt ueber Wasser = %+.3f m  ->  NDC y = %+.4f",
                 worstAbove, worstNdc))
    print("============================================")
}

MainActor.assumeIsolated { main() }
