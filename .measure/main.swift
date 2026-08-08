// Beweis: Kann die aktuelle Wellenformel überhaupt überhängen?
// Ein Überhang existiert genau dann, wenn die Abbildung Parameter->Welt in z
// nicht mehr monoton ist, also die Jacobi-Determinante dz_welt/dz_param <= 0 wird.

import simd
import Foundation

let wave = WaveField()
let time: Float = 0
let scrollZ: Float = 0

var minJac = Float.greatestFiniteMagnitude
var minJacAt: Float = 0
let eps: Float = 0.001

for i in 0...20000 {
    let rz = -40 + Float(i) * 0.004        // Parameterraum entlang der Wellenachse
    let z = rz - wave.crestShift
    let d0 = wave.displacement(x: 0, z: z - eps, time: time, scrollZ: scrollZ)
    let d1 = wave.displacement(x: 0, z: z + eps, time: time, scrollZ: scrollZ)
    // Weltposition = Parameter + Verschiebung. Jacobi = d(welt_z)/d(param_z)
    let jac = 1 + (d1.z - d0.z) / (2 * eps)
    if jac < minJac { minJac = jac; minJacAt = rz }
}

print(String(format: "minimale Jacobi-Determinante dz_welt/dz_param = %.4f bei rz = %.2f", minJac, minJacAt))
print("Überhang moeglich? \(minJac < 0)  (nur bei Werten < 0 faltet sich die Flaeche)")

// Wie viel mehr z-Verschiebung waere noetig?
print(String(format: "Faktor bis zur Faltung: %.2fx mehr z-Auslenkung noetig", 1 / max(1 - minJac, 0.0001)))

// Gegenprobe: zwei Oberflaechenhoehen an derselben Welt-z-Position?
var mapped: [Float] = []
mapped.reserveCapacity(20001)
for j in 0...20000 {
    let param = -40 + Float(j) * 0.004
    let d = wave.displacement(x: 0, z: param - wave.crestShift, time: time, scrollZ: scrollZ)
    mapped.append(param - wave.crestShift + d.z)
}
var maxHits = 0
var maxHitsZ: Float = 0
for i in 0...2000 {
    let worldZ = -20 + Float(i) * 0.02
    var hits = 0
    for j in 1..<mapped.count where (mapped[j - 1] - worldZ) * (mapped[j] - worldZ) < 0 {
        hits += 1
    }
    if hits > maxHits { maxHits = hits; maxHitsZ = worldZ }
}
print("maximale Zahl von Oberflaechen an einer Welt-z-Position: \(maxHits) (bei z=\(maxHitsZ))")
print("Barrel vorhanden? \(maxHits >= 3)   (1 = einfache Flaeche, >=3 = Ueberhang)")
