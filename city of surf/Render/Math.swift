//
//  Math.swift
//  city of surf
//

import simd

enum Math {
    static func rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
        let unitAxis = normalize(axis)
        let ct = cosf(radians)
        let st = sinf(radians)
        let ci = 1 - ct
        let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
        return matrix_float4x4(columns: (
            SIMD4(ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
            SIMD4(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
            SIMD4(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func translation(_ t: SIMD3<Float>) -> matrix_float4x4 {
        matrix_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        ))
    }

    static func scale(_ s: SIMD3<Float>) -> matrix_float4x4 {
        matrix_float4x4(columns: (
            SIMD4(s.x, 0, 0, 0),
            SIMD4(0, s.y, 0, 0),
            SIMD4(0, 0, s.z, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func perspective(fovyRadians fovy: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
        let ys = 1 / tanf(fovy * 0.5)
        let xs = ys / aspectRatio
        let zs = farZ / (nearZ - farZ)
        return matrix_float4x4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * nearZ, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let z = simd_normalize(eye - target)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        let t = SIMD3(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye))
        return matrix_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(t.x, t.y, t.z, 1)
        ))
    }

    static func radians(_ degrees: Float) -> Float {
        degrees / 180 * .pi
    }
}
